# app/ibkr_api.py
from __future__ import annotations
import os, math, logging, json, time
from pathlib import Path
from fastapi import APIRouter, HTTPException, Body, Query
import subprocess, shlex
from pathlib import Path
import re
from fastapi.responses import StreamingResponse
from ib_insync import IB, util, Stock, Forex, Future, Contract, Order, MarketOrder, LimitOrder, BarData
from typing import Any, Callable
import asyncio
from collections import defaultdict, deque
from datetime import datetime, timezone

router = APIRouter(prefix="/ibkr", tags=["ibkr"])
log = logging.getLogger("ibkr")

IB_HOST = os.getenv("IB_HOST", "127.0.0.1")
IB_CLIENT_ID = int(os.getenv("IB_CLIENT_ID", "11"))
IBC_INI_PATH = Path("/opt/ibc/config.ini")

# Make ib_insync safe under ASGI/Jupyter nested loops
try:
    util.patchAsyncio()
except Exception:
    pass
ib = IB()

RUNTIME = Path(os.getenv("TB_RUNTIME_DIR", Path(__file__).resolve().parent.parent / "runtime"))
RUNTIME.mkdir(parents=True, exist_ok=True)
ORDERS_LOG = RUNTIME / "orders.log"
CACHE_DIR = RUNTIME / "cache"
CACHE_DIR.mkdir(parents=True, exist_ok=True)
XPRA_TOGGLE = RUNTIME / "xpra_main_enabled.conf"

def _safe_name(s: str) -> str:
    return re.sub(r"[^A-Za-z0-9_.-]+", "_", s)[:180]

def _cache_path(name: str) -> Path:
    return CACHE_DIR / name

def _cache_write(name: str, data: Any) -> None:
    try:
        p = _cache_path(name)
        tmp = p.with_suffix(p.suffix + ".tmp")
        tmp.write_text(json.dumps(data, separators=(",", ":")), encoding="utf-8")
        tmp.replace(p)
    except Exception:
        pass

def _cache_read(name: str, default: Any) -> Any:
    try:
        p = _cache_path(name)
        if not p.exists():
            return default
        return json.loads(p.read_text(encoding="utf-8"))
    except Exception:
        return default
IBC_ENV = RUNTIME / "ibc.env"

# ---------- order streaming state ----------
ORD_QUEUE: "asyncio.Queue[dict]" = asyncio.Queue(maxsize=1000)

def _order_trade_to_dict(t) -> dict:
    c = t.contract
    o = t.order
    st = t.orderStatus
    return {
        "ts": int(time.time()),
        "event": "tradeUpdate",
        "orderId": getattr(o, "orderId", None),
        "permId": getattr(o, "permId", None),
        "symbol": getattr(c, "localSymbol", None) or getattr(c, "symbol", None),
        "conId": getattr(c, "conId", None),
        "secType": getattr(c, "secType", None),
        "action": getattr(o, "action", None),
        "type": getattr(o, "orderType", None),
        "lmt": getattr(o, "lmtPrice", None),
        "tif": getattr(o, "tif", None),
        "qty": getattr(o, "totalQuantity", None),
        "status": getattr(st, "status", None),
        "filled": getattr(st, "filled", None),
        "remaining": getattr(st, "remaining", None),
        "avgFillPrice": getattr(st, "avgFillPrice", None),
    }

def _attach_trade_listener(trade):
    """
    Attach a listener to a Trade that fires on any meaningful change.
    Different ib_insync versions expose different events, so we probe a set.
    """
    async def _emit_snapshot():
        try:
            ORD_QUEUE.put_nowait(_order_trade_to_dict(trade))
        except asyncio.QueueFull:
            pass

    def _on_any(_=None, *args, **kwargs):
        try:
            asyncio.get_running_loop().create_task(_emit_snapshot())
        except RuntimeError:
            # Not in an event loop yet; ignore
            pass

    # Try a range of possible event names across ib_insync versions.
    for evname in (
        "updateEvent",              # some builds had this
        "statusEvent",              # status changes
        "filledEvent", "fillEvent", # fills
        "commissionReportEvent",    # commission updates
        "cancelledEvent",           # cancellations
        "modifyEvent",              # modifications
        "logEvent",                 # generic trade log entries
    ):
        ev = getattr(trade, evname, None)
        if ev is not None:
            try:
                ev += _on_any
            except Exception:
                pass

    # Emit an initial snapshot so clients get immediate state.
    try:
        loop = asyncio.get_running_loop()
        loop.create_task(_emit_snapshot())
    except RuntimeError:
        pass

# ---------- news streaming state ----------
# in-memory state; simple and sturdy for single-process FastAPI
NEWS_SEEN: dict[int, set[str]] = defaultdict(set)    # tickerId -> set(articleId)
NEWS_RECENT: deque[dict] = deque(maxlen=400)         # rolling buffer for SSE replay
NEWS_QUEUE: "asyncio.Queue[dict]" = asyncio.Queue(maxsize=1000)
NEWS_WATCH_SYMBOL: dict[str, Any] = {}               # symbol -> Ticker (per-symbol news)
NEWS_WATCH_PROVIDER: dict[str, Any] = {}             # providerCode -> Ticker (provider-wide news)
# keep callbacks so we can detach them on unsubscribe
NEWS_CB_SYMBOL: dict[str, Callable] = {}
NEWS_CB_PROVIDER: dict[str, Callable] = {}
# map a synthetic ticker id to clear NEWS_SEEN
NEWS_TID_BY_SYMBOL: dict[str, int] = {}
NEWS_TID_BY_PROVIDER: dict[str, int] = {}
# Optional provider allowlist via env, e.g. "BZ,FLY,DJNL,BRFG"
_env_providers = (os.getenv("IB_NEWS_PROVIDERS","").strip() or "")
NEWS_PROVIDER_ALLOW = {p.strip() for p in _env_providers.split(",") if p.strip()}


async def _ensure_connected():
    if ib.isConnected():
        return
    try:
        await ib.connectAsync(IB_HOST, _current_port(), clientId=IB_CLIENT_ID, timeout=4)
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"IBKR connect failed: {e!s}")

def _safe_get(obj, attr, fallback=""):
    return getattr(obj, attr, None) or fallback

def _read_ibc_env() -> dict:
    env = {}
    if IBC_ENV.exists():
        for line in IBC_ENV.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip()
    return env

def _current_port() -> int:
    """
    Resolve IB API port dynamically:
      - prefer runtime ibc.env if present,
      - else fall back to process env,
      - else 4002.
    """
    env = _read_ibc_env()
    return int(env.get("IB_PORT") or os.getenv("IB_PORT", "4002"))

def _write_ibc_env(env: dict):
    lines = []
    for k in ("IB_USER","IB_PASSWORD","IB_TOTP_SECRET","IB_MODE","IB_PORT","DISPLAY"):
        if k in env:
            lines.append(f"{k}={env[k]}")
    IBC_ENV.write_text("\n".join(lines) + "\n", encoding="utf-8")
    try:
        IBC_ENV.chmod(0o600)
    except Exception:
        pass

def _update_ibc_config_ini_from_env(env: dict) -> None:
    """
    Keep /opt/ibc/config.ini in sync with UI-provided creds/mode so IBC can
    log in headlessly after a restart. We only touch a small set of keys.
    """
    try:
        # read existing lines (ini format is simple key=value, no sections)
        lines = []
        if IBC_INI_PATH.exists():
            lines = [ln.rstrip("\n") for ln in IBC_INI_PATH.read_text(encoding="utf-8").splitlines()]
        d = {k.split("=",1)[0]: k.split("=",1)[1] for k in lines if "=" in k}
        # update keys
        if env.get("IB_USER"):
            d["IbLoginId"] = env["IB_USER"]
        if env.get("IB_PASSWORD") is not None and env.get("IB_PASSWORD") != "":
            d["IbPassword"] = env["IB_PASSWORD"]
        mode = (env.get("IB_MODE","paper") or "paper").lower()
        d["TradingMode"] = "live" if mode == "live" else "paper"
        # 2FA
        totp = env.get("IB_TOTP_SECRET","")
        if totp:
            d["TwoFactorMethod"] = "totp"
            d["TwoFactorSecret"] = totp
        else:
            d["TwoFactorMethod"] = "none"
            d.pop("TwoFactorSecret", None)
        # write back
        body = "\n".join(f"{k}={v}" for k,v in d.items()) + "\n"
        IBC_INI_PATH.write_text(body, encoding="utf-8")
    except Exception:
        pass

def _sudo(cmd: str) -> subprocess.CompletedProcess:
    # uses sudoers rules from installer
    return subprocess.run(shlex.split(f"sudo {cmd}"),
                          stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE,
                          text=True)

# -------- IBC config (credentials/mode) -------------------------------------
@router.get("/ibc/config")
async def ibc_config_get():
    env = _read_ibc_env()
    return {
        "IB_USER": env.get("IB_USER",""),
        "IB_MODE": env.get("IB_MODE","paper"),
        "IB_PORT": env.get("IB_PORT","4002"),
        "IB_TOTP_SECRET_SET": bool(env.get("IB_TOTP_SECRET","")),
    }

@router.post("/ibc/config")
async def ibc_config_set(payload: dict = Body(...)):
    """
    Body: { user, password, totp, mode('paper'|'live'), restart: bool }
    - Empty password/totp fields do NOT overwrite existing values.
    """
    env = _read_ibc_env()
    user = (payload.get("user") or "").strip()
    pwd  = payload.get("password") or ""
    totp = (payload.get("totp") or "").strip()
    mode = (payload.get("mode") or env.get("IB_MODE","paper")).lower()
    if user:
        env["IB_USER"] = user
    if pwd != "":
        env["IB_PASSWORD"] = pwd
    if totp != "":
        env["IB_TOTP_SECRET"] = totp
    env["IB_MODE"] = "live" if mode == "live" else "paper"
    # Port strategy:
    # - If payload specifies 'port', use it.
    # - Else, track the mode: live->4001, paper->4002 (sane defaults).
    port_override = (payload.get("port") or "").strip()
    if port_override:
        env["IB_PORT"] = port_override
    else:
        env["IB_PORT"] = "4001" if env["IB_MODE"] == "live" else "4002"
    env.setdefault("DISPLAY", ":100")
    _write_ibc_env(env)
    _update_ibc_config_ini_from_env(env)
    if payload.get("restart"):
        r = _sudo("systemctl restart xpra-ibgateway-main.service")
        if r.returncode != 0:
            raise HTTPException(500, f"restart failed: {r.stderr.strip() or r.stdout.strip()}")
    return {"ok": True, "port": env.get("IB_PORT")}

# -------- Debug viewer toggle (Nginx-gated /xpra-main/) ----------------------
@router.get("/ibc/debugviewer/status")
async def debugviewer_status():
    try:
        s = XPRA_TOGGLE.read_text(encoding="utf-8")
    except Exception:
        s = ""
    active = " 1" in (" " + s.strip()) or "set $xpra_main_enabled 1" in s
    return {"active": active, "url": "/xpra-main/"}

@router.post("/ibc/debugviewer")
async def debugviewer_set(payload: dict = Body(...)):
    enable = bool(payload.get("enabled"))
    try:
        XPRA_TOGGLE.write_text(f"set $xpra_main_enabled {1 if enable else 0};\n", encoding="utf-8")
    except Exception as e:
        raise HTTPException(500, f"toggle write failed: {e!s}")
    r = _sudo("nginx -t")
    if r.returncode != 0:
        raise HTTPException(500, f"nginx conf test failed: {r.stderr.strip() or r.stdout.strip()}")
    r = _sudo("systemctl reload nginx")
    if r.returncode != 0:
        raise HTTPException(500, f"nginx reload failed: {r.stderr.strip() or r.stdout.strip()}")
    return await debugviewer_status()

@router.get("/ping")
async def ping():
    """
    Health probe that never throws. Returns connected: true/false.
    """
    try:
        if not ib.isConnected():
            await ib.connectAsync(IB_HOST, IB_PORT, clientId=IB_CLIENT_ID, timeout=3)
        dt = await ib.reqCurrentTimeAsync()
        out = {"connected": True, "server_time": dt.isoformat()}
        _cache_write("ping.json", out)
        return out
    except Exception as e:
        cached = _cache_read("ping.json", None)
        return {"connected": False, "error": str(e), "last_ok": cached.get("server_time") if isinstance(cached, dict) else None}
    
def _num_or_none(x):
    """Cast to float and drop NaN/Inf to None so JSON stays valid."""
    if x is None:
        return None
    try:
        v = float(x)
        return v if math.isfinite(v) else None
    except Exception:
        return None

@router.get("/accounts")
async def accounts():
    try:
        await _ensure_connected()
        rows = await ib.accountSummaryAsync()
        out = {}
        for r in rows:
            acct = r.account
            out.setdefault(acct, {})[r.tag] = r.value
        _cache_write("accounts.json", out)
        return out
    except Exception as e:
        cached = _cache_read("accounts.json", None)
        if cached is not None:
            return cached
        raise HTTPException(503, f"IBKR offline and no account cache: {e}")
    
# ---------- NEWS: providers, subscribe, SSE ---------------------------------
@router.get("/news/providers")
async def news_providers():
    await _ensure_connected()
    provs = await ib.reqNewsProvidersAsync()
    return [{"code": p.code, "name": p.name} for p in provs]

def _mk_stock(symbol: str) -> Contract:
    return Stock(symbol, 'SMART', 'USD')

def _mk_news_provider_contract(code: str) -> Contract:
    """
    Broad tape for a provider. Example (Briefing.com):
      symbol='BRFG:BRFG_ALL', secType='NEWS', exchange='BRFG'
    Works similarly for BZ, DJNL, FLY, MT, etc.
    """
    c = Contract()
    c.secType = 'NEWS'
    c.exchange = code
    c.symbol = f"{code}:{code}_ALL"
    return c

def _news_tick_to_dict(scope: str, n, symbol: str | None = None, provider: str | None = None) -> dict:
    # n: ib_insync.types.NewsTick
    ts = n.time if isinstance(n.time, datetime) else util.parseIBDatetime(n.time)
    # normalize to aware UTC
    if ts.tzinfo is None:
        ts = ts.replace(tzinfo=timezone.utc)
    ts_utc = ts.astimezone(timezone.utc)
    return {
        "ts": int(ts_utc.timestamp()),
        "time": ts_utc.isoformat().replace("+00:00", "Z"),
        "provider": provider or n.providerCode,
        "articleId": n.articleId,
        "headline": n.text,
        "symbol": symbol,          # null for provider-wide
        "scope": scope,            # "provider" | "symbol"
    }

def _ticker_callback_factory_symbol(symbol: str, tickerId: int):
    async def _emit(item: dict):
        NEWS_RECENT.append(item)
        try:
            NEWS_QUEUE.put_nowait(item)
        except asyncio.QueueFull:
            # drop oldest if overwhelmed
            _ = NEWS_RECENT.popleft() if NEWS_RECENT else None
    def _on_update(_):
        # Called on any ticker update; process new headlines only
        tkr = NEWS_WATCH_SYMBOL.get(symbol)
        if not tkr or not tkr.news:
            return
        for n in tkr.news[-3:]:  # scan last few to avoid O(N)
            aid = getattr(n, "articleId", "") or ""
            prov = getattr(n, "providerCode", "") or ""
            if aid in NEWS_SEEN[tickerId]:
                continue
            if NEWS_PROVIDER_ALLOW and prov not in NEWS_PROVIDER_ALLOW:
                NEWS_SEEN[tickerId].add(aid)
                continue
            NEWS_SEEN[tickerId].add(aid)
            item = _news_tick_to_dict("symbol", n, symbol=symbol, provider=prov)
            # schedule enqueue on current loop
            asyncio.get_running_loop().create_task(_emit(item))
    return _on_update

def _ticker_callback_factory_provider(providerCode: str, tickerId: int):
    async def _emit(item: dict):
        NEWS_RECENT.append(item)
        try:
            NEWS_QUEUE.put_nowait(item)
        except asyncio.QueueFull:
            _ = NEWS_RECENT.popleft() if NEWS_RECENT else None
    def _on_update(_):
        tkr = NEWS_WATCH_PROVIDER.get(providerCode)
        if not tkr or not tkr.news:
            return
        for n in tkr.news[-6:]:  # scan a few; provider feeds can be chatty
            aid = getattr(n, "articleId", "") or ""
            prov = getattr(n, "providerCode", "") or providerCode
            if NEWS_PROVIDER_ALLOW and prov not in NEWS_PROVIDER_ALLOW:
                # still mark as seen to prevent reprocessing
                NEWS_SEEN[tickerId].add(aid)
                continue
            if aid in NEWS_SEEN[tickerId]:
                continue
            NEWS_SEEN[tickerId].add(aid)
            item = _news_tick_to_dict("provider", n, symbol=None, provider=prov)
            asyncio.get_running_loop().create_task(_emit(item))
    return _on_update

@router.post("/news/subscribe")
async def news_subscribe(payload: dict = Body(...)):
    """
    Subscribe to **provider-wide** or **per-symbol** headlines.
    Body (choose one mode):
      - Provider-wide: { "providers": ["BZ","DJNL","BRFG","FLY"] }
      - Per-symbol:    { "symbols": ["AAPL","NVDA"] }  (kept for backward-compat)
    If the env var IB_NEWS_PROVIDERS is set, it acts as an allowlist.
    """
    await _ensure_connected()
    syms = list({s.strip().upper() for s in (payload.get("symbols") or []) if isinstance(s, str) and s.strip()})
    provs = list({p.strip().upper() for p in (payload.get("providers") or []) if isinstance(p, str) and p.strip()})

    if not syms and not provs:
        raise HTTPException(400, "provide either 'providers' or 'symbols'")

    created_providers, created_symbols = [], []

    # Provider-wide mode
    if provs:
        for code in provs:
            if NEWS_PROVIDER_ALLOW and code not in NEWS_PROVIDER_ALLOW:
                continue
            if code in NEWS_WATCH_PROVIDER:
                created_providers.append(code)
                continue
            nc = _mk_news_provider_contract(code)  # NEWS contract per provider
            # 'mdoff,292' avoids regular market data for this pseudo-contract; 292 is the news tick. 
            tkr = ib.reqMktData(nc, genericTickList="mdoff,292", snapshot=False)
            tid = id(tkr)
            cb = _ticker_callback_factory_provider(code, tid)
            tkr.updateEvent += cb
            NEWS_WATCH_PROVIDER[code] = tkr
            NEWS_CB_PROVIDER[code] = cb
            NEWS_TID_BY_PROVIDER[code] = tid
            created_providers.append(code)

    # Per-symbol mode (legacy / optional)
    if syms:
        for sym in syms:
            if sym in NEWS_WATCH_SYMBOL:
                created_symbols.append(sym)
                continue
            c = _mk_stock(sym)
            tkr = ib.reqMktData(c, genericTickList="292", snapshot=False)
            tid = id(tkr)
            cb = _ticker_callback_factory_symbol(sym, tid)
            tkr.updateEvent += cb
            NEWS_WATCH_SYMBOL[sym] = tkr
            NEWS_CB_SYMBOL[sym] = cb
            NEWS_TID_BY_SYMBOL[sym] = tid
            created_symbols.append(sym)

    return {
        "ok": True,
        "providers": created_providers,
        "symbols": created_symbols,
        "allowlist": sorted(NEWS_PROVIDER_ALLOW) or None
    }
@router.post("/news/unsubscribe")
async def news_unsubscribe(payload: dict = Body(...)):
    """
    Body: { "providers": ["BZ","DJNL"], "symbols": ["AAPL"] } — both optional; at least one required.
    """
    await _ensure_connected()
    symbols = list({s.strip().upper() for s in (payload.get("symbols") or []) if isinstance(s, str) and s.strip()})
    providers = list({p.strip().upper() for p in (payload.get("providers") or []) if isinstance(p, str) and p.strip()})
    if not symbols and not providers:
        raise HTTPException(400, "providers or symbols required")
    removed_syms, removed_provs = [], []
    for sym in symbols:
        tkr = NEWS_WATCH_SYMBOL.pop(sym, None)
        if tkr:
            try:
                # detach callback and clear seen set
                cb = NEWS_CB_SYMBOL.pop(sym, None)
                if cb is not None:
                    tkr.updateEvent -= cb
                tid = NEWS_TID_BY_SYMBOL.pop(sym, None)
                if tid is not None:
                    NEWS_SEEN.pop(tid, None)
                ib.cancelMktData(tkr.contract)
            except Exception:
                pass
            removed_syms.append(sym)
    for code in providers:
        tkr = NEWS_WATCH_PROVIDER.pop(code, None)
        if tkr:
            try:
                cb = NEWS_CB_PROVIDER.pop(code, None)
                if cb is not None:
                    tkr.updateEvent -= cb
                tid = NEWS_TID_BY_PROVIDER.pop(code, None)
                if tid is not None:
                    NEWS_SEEN.pop(tid, None)
                ib.cancelMktData(tkr.contract)
            except Exception:
                pass
            removed_provs.append(code)
    return {"ok": True, "removed": {"providers": removed_provs, "symbols": removed_syms}}
    
@router.get("/news/status")
async def news_status():
    return {
        "providers": sorted(list(NEWS_WATCH_PROVIDER.keys())),
        "symbols": sorted(list(NEWS_WATCH_SYMBOL.keys())),
        "buffer": len(NEWS_RECENT),
        "queueSize": NEWS_QUEUE.qsize(),
        "allowlist": sorted(NEWS_PROVIDER_ALLOW) or None,
    }

@router.get("/news/stream")
async def news_stream():
    """
    Server-Sent Events stream of headlines.
    Sends a small recent replay, then live items.
    """
    await _ensure_connected()
    async def _gen():
        try:
            # replay last 50
            for it in list(NEWS_RECENT)[-50:]:
                yield f"event: news\ndata: {json.dumps(it, separators=(',',':'))}\n\n"
            # live
            while True:
                item = await NEWS_QUEUE.get()
                yield f"event: news\ndata: {json.dumps(item, separators=(',',':'))}\n\n"
        except asyncio.CancelledError:
            # client disconnected
            return
    return StreamingResponse(_gen(), media_type="text/event-stream")

@router.get("/positions")
async def positions():
    try:
        await _ensure_connected()
        try:
            if hasattr(ib, "reqPositionsAsync"):
                pos = await ib.reqPositionsAsync()
            else:
                ib.reqPositions()
                await asyncio.sleep(1.0)
                pos = list(ib.positions())
        finally:
            try: ib.cancelPositions()
            except Exception: pass
        out = []
        for p in (pos or []):
            try:
                c = p.contract
                symbol   = getattr(c, "localSymbol", None) or getattr(c, "symbol", None) or str(getattr(c, "conId", ""))
                secType  = getattr(c, "secType", None)
                currency = getattr(c, "currency", None)
                exchange = getattr(c, "primaryExchange", None) or getattr(c, "exchange", None)
                out.append({
                    "account": p.account,
                    "symbol": symbol,
                    "secType": secType,
                    "currency": currency,
                    "exchange": exchange,
                    "conId": _safe_get(c, "conId"),
                    "position": _num_or_none(p.position),
                    "avgCost": _num_or_none(p.avgCost),
                })
            except Exception:
                continue
        _cache_write("positions.json", out)
        return out
    except Exception as e:
        cached = _cache_read("positions.json", None)
        if cached is not None:
            return cached
        raise HTTPException(503, f"IBKR offline and no positions cache: {e}")
    
# ---------- helpers ----------
async def _resolve_contract(
    symbol: str,
    secType: str = "STK",
    exchange: str = "SMART",
    currency: str = "USD",
    expiry: str | None = None,
):
    """Resolve to a unique Contract using reqContractDetails."""
    await _ensure_connected()
    base: Contract
    st = secType.upper()
    if st == "STK":
        base = Stock(symbol, exchange, currency)
    elif st == "FX" or st == "CASH":
        base = Forex(symbol)  # e.g. "EURUSD"
    elif st == "FUT":
        base = Future(symbol, lastTradeDateOrContractMonth=expiry or "", exchange=exchange, currency=currency)
    else:
        base = Contract(secType=st, symbol=symbol, exchange=exchange, currency=currency)
    cds = await ib.reqContractDetailsAsync(base)
    if not cds:
        raise HTTPException(404, detail=f"No contract for {symbol}/{secType}")
    # Prefer SMART/primaryExchange when present
    c = cds[0].contract
    return c

def _contract_json(c: Contract) -> dict:
    return {
        "conId": c.conId,
        "symbol": c.symbol,
        "localSymbol": getattr(c, "localSymbol", None),
        "secType": c.secType,
        "currency": c.currency,
        "exchange": c.exchange,
        "primaryExchange": getattr(c, "primaryExchange", None),
        "lastTradeDateOrContractMonth": getattr(c, "lastTradeDateOrContractMonth", None),
    }

# ---------- orders log ----------
def _log_order(event: str, payload: dict):
    try:
        rec = {"ts": int(time.time()), "event": event, **payload}
        with ORDERS_LOG.open("a", encoding="utf-8") as f:
            f.write(json.dumps(rec, separators=(",", ":")) + "\n")
    except Exception:
        pass

# ---------- orders ----------
@router.get("/orders/open")
async def orders_open():
    try:
        await _ensure_connected()
        openTrades = ib.openTrades()
        out = []
        for t in openTrades:
            c = t.contract
            o = t.order
            st = t.orderStatus
            out.append({
                "orderId": o.orderId,
                "permId": o.permId,
                "symbol": getattr(c, "localSymbol", None) or c.symbol,
                "conId": getattr(c, "conId", None),
                "secType": c.secType,
                "action": o.action,
                "type": o.orderType,
                "lmt": getattr(o, "lmtPrice", None),
                "tif": o.tif,
                "qty": o.totalQuantity,
                "status": st.status,
                "filled": st.filled,
                "remaining": st.remaining,
            })
        _cache_write("orders_open.json", out)
        return out
    except Exception as e:
        cached = _cache_read("orders_open.json", None)
        if cached is not None:
            return cached
        raise HTTPException(503, f"IBKR offline and no open orders cache: {e}")

@router.get("/orders/stream")
async def orders_stream():
    """
    Server-Sent Events for order/trade updates.
    On connect: emits a snapshot of current open trades, then pushes live updates.
    """
    await _ensure_connected()
    # attach listeners to existing trades so further updates are pushed
    for t in ib.openTrades():
        _attach_trade_listener(t)
    # also attach to any new trades created later
    def _on_new_trade(trade):
        _attach_trade_listener(trade)
    ib.newOrderEvent += _on_new_trade

    async def _gen():
        # initial snapshot (open)
        for t in ib.openTrades():
            yield f"event: trade\ndata: {json.dumps(_order_trade_to_dict(t), separators=(',',':'))}\n\n"
        try:
            while True:
                item = await ORD_QUEUE.get()
                yield f"event: trade\ndata: {json.dumps(item, separators=(',',':'))}\n\n"
        except asyncio.CancelledError:
            return
        finally:
            try:
                ib.newOrderEvent -= _on_new_trade
            except Exception:
                pass
    return StreamingResponse(_gen(), media_type="text/event-stream")

@router.get("/orders/history")
async def orders_history(limit: int = 200):
    if not ORDERS_LOG.exists():
        return []
    rows = ORDERS_LOG.read_text(encoding="utf-8").splitlines()
    return [json.loads(x) for x in rows[-abs(limit):] if x.strip()]
    
# --- helpers ---------------------------------------------------------------
async def _account_code() -> str:
    await _ensure_connected()
    accts = ib.managedAccounts()
    if not accts:
        # fallback: infer from accountSummary
        rows = await ib.accountSummaryAsync()
        accts = sorted({r.account for r in rows})
    if not accts:
        raise HTTPException(502, "No IBKR account code available")
    return accts[0]

def _mk_contract(symbol: str | None = None, conId: int | None = None, exchange: str | None = None, secType: str | None = None, currency: str | None = None) -> Contract:
    if conId:
        c = Contract(conId=conId)
        if exchange: c.exchange = exchange
        return c
    if not symbol:
        raise HTTPException(400, "symbol or conId required")
    # default to SMART/US stocks unless specified
    c = Stock(symbol, exchange or 'SMART', currency or 'USD')
    return c

async def _qualify(c: Contract) -> Contract:
    """Best-effort qualification so exchange/currency are present."""
    try:
        qc = await ib.qualifyContractsAsync(c)
        if qc:
            return qc[0]
    except Exception:
        pass
    return c

async def _await_status(trade, beats: int = 12, delay: float = 0.10):
    """
    Give TWS a brief moment to attach an initial orderStatus (Submitted/PreSubmitted/…).
    """
    for _ in range(max(1, beats)):
        st = getattr(trade, "orderStatus", None)
        if st and getattr(st, "status", None):
            return st
        await asyncio.sleep(delay)
    return getattr(trade, "orderStatus", None)

# --- search/contracts (find tradables by text) -----------------------------
@router.get("/search")
async def search(q: str | None = Query(None), query: str | None = Query(None)):
    # Online-first; fall back to cached matching if offline
    try:
        await _ensure_connected()
    except Exception:
        term = (q or query or "").strip()
        if not term:
            return []
        cache = _cache_read("search_cache.json", {})
        if not isinstance(cache, dict):
            return []
        tl = term.lower()
        # soft match across cached keys and values
        merged: list[dict] = []
        seen = set()
        for k, vals in cache.items():
            if tl in k.lower():
                for m in (vals or []):
                    cid = (m.get("conId") or 0)
                    if cid and cid in seen: continue
                    seen.add(cid)
                    merged.append(m)
        # also scan values' 'name' for contains
        if len(merged) < 5:
            for vals in cache.values():
                for m in (vals or []):
                    name = (m.get("name") or m.get("description") or "")
                    if tl in str(name).lower():
                        cid = (m.get("conId") or 0)
                        if cid and cid in seen: continue
                        seen.add(cid)
                        merged.append(m)
        return merged[:50]
    term = (q or query or "").strip()
    if not term:
        return []

    async def _query_and_collect(qtext: str, out: list[dict]):
        """Run reqMatchingSymbols on qtext and append normalized rows into out."""
        try:
            syms = await ib.reqMatchingSymbolsAsync(qtext)
        except Exception as e:
            # return silently so other variants still try
            return
        for s in (syms or []):
            for desc in (getattr(s, "contractDescriptions", None) or []):
                try:
                    c = getattr(desc, "contract", None)
                    if not c:
                        continue
                    # Qualify only if missing conId/exchange/currency
                    need_qual = not getattr(c, "conId", None) or not getattr(c, "exchange", None) or not getattr(c, "currency", None)
                    if need_qual:
                        try:
                            qc = (await ib.qualifyContractsAsync(c)) or []
                            c = qc[0] if qc else c
                        except Exception:
                            pass
                    out.append({
                        "symbol": s.symbol or getattr(c, "symbol", None) or qtext.upper(),
                        "name": s.description or getattr(c, "localSymbol", None) or getattr(c, "symbol", None) or qtext.upper(),
                        "secType": getattr(c, "secType", None) or "STK",
                        "conId": int(getattr(c, "conId", 0)) or None,
                        "currency": getattr(c, "currency", None) or "USD",
                        "exchange": getattr(c, "primaryExchange", None) or getattr(c, "exchange", None) or "SMART",
                    })
                except Exception:
                    continue

    # 1) Primary attempt
    out: list[dict] = []
    await _query_and_collect(term, out)

    # 2) If weak or empty, try robust variants (helps for "Tesla", "Micro Soft", etc.)
    if len(out) < 5:
        variants: list[str] = []
        # case variants
        variants += [term.upper(), term.lower(), term.title()]
        # de-space & punctuation stripped
        compact = re.sub(r"\s+", "", term)
        if compact and compact != term:
            variants.append(compact)
        # tokenized words (length >= 3), e.g., ["Tesla", "Motors", "Inc"]
        tokens = [t for t in re.split(r"[^A-Za-z0-9]+", term) if len(t) >= 3]
        variants += tokens
        # unique order-preserving
        seen_v = set()
        variants = [v for v in variants if not (v in seen_v or seen_v.add(v))]
        for v in variants[:8]:  # keep it sane
            await _query_and_collect(v, out)

    # De-dup by conId (keep first)
    seen: set[int] = set()
    uniq: list[dict] = []
    for d in out:
        cid = d.get("conId")
        if not cid:   # keep those without conId too (rare)
            uniq.append(d)
            continue
        if cid in seen:
            continue
        seen.add(cid)
        uniq.append(d)

    # Soft-rank: prefer rows whose 'name' contains the term (case-insensitive)
    tl = term.lower()
    uniq.sort(key=lambda r: 0 if tl in (r.get("name","") or "").lower() else 1)

    # Fallback: try direct resolve if nothing matched (e.g., “AAPL”, “EURUSD”)
    if not uniq:
        # Try stock
        try:
            c = await _resolve_contract(term, "STK", "SMART", "USD")
            uniq.append({
                "symbol": getattr(c, "localSymbol", None) or getattr(c, "symbol", None) or term.upper(),
                "name": getattr(c, "symbol", None) or term.upper(),
                "secType": getattr(c, "secType", None) or "STK",
                "conId": int(getattr(c, "conId", 0)) or None,
                "currency": getattr(c, "currency", None) or "USD",
                "exchange": getattr(c, "primaryExchange", None) or getattr(c, "exchange", None) or "SMART",
            })
        except Exception:
            # Try FX (EURUSD style)
            try:
                cfx = await _resolve_contract(term, "FX", "IDEALPRO", "USD")
                uniq.append({
                    "symbol": getattr(cfx, "localSymbol", None) or getattr(cfx, "symbol", None) or term.upper(),
                    "name": getattr(cfx, "symbol", None) or term.upper(),
                    "secType": getattr(cfx, "secType", None) or "FX",
                    "conId": int(getattr(cfx, "conId", 0)) or None,
                    "currency": getattr(cfx, "currency", None) or "USD",
                    "exchange": getattr(cfx, "primaryExchange", None) or getattr(cfx, "exchange", None) or "IDEALPRO",
                })
            except Exception:
                pass

    # cache successful results under the normalized key (plus variants)
    try:
        cache = _cache_read("search_cache.json", {})
        if not isinstance(cache, dict): cache = {}
        norm = term.strip()
        cache[norm] = uniq[:50]
        _cache_write("search_cache.json", cache)
    except Exception:
        pass
    return uniq[:50]

# --- quotes (last/bid/ask/high/low/close) ----------------------------------
@router.get("/quote")
async def quote(
    symbol: str | None = None,
    conId: int | None = None,
    secType: str | None = None,
    exchange: str | None = None,
    currency: str | None = None,
):
    cache_key = f"quote-{_safe_name(str(conId or 'sym-'+str(symbol or '')))}.json"
    try:
        await _ensure_connected()
    except Exception as e:
        cached = _cache_read(cache_key, None)
        if cached is not None:
            return cached
        # fall through to return an empty-like structure
    c = _mk_contract(symbol, conId, exchange, secType, currency)
    # qualify conId-only contracts so exchange/currency are present
    if conId and (not getattr(c, "exchange", None) or not getattr(c, "currency", None)):
        try:
            [c] = await ib.qualifyContractsAsync(c)
        except Exception:
            pass
    try:
        tkrs = await ib.reqTickersAsync(c)
        t = tkrs[0] if tkrs else None
        if not t or all(getattr(t, f, None) is None for f in ("last", "close", "bid", "ask")):
            # one-shot snapshot fallback (for accounts without live ticks)
            tkr = ib.reqMktData(c, snapshot=True)
            await asyncio.sleep(0.25)
            ib.cancelMktData(c)
            t = next((x for x in ib.tickers() if x.contract.conId == getattr(c, "conId", None)), None)
    except Exception as e:
        raise HTTPException(502, detail=f"quote failed: {e!s}")
    out = {
            "conId": getattr(c, "conId", None),
            "symbol": getattr(c, "localSymbol", None) or getattr(c, "symbol", None),
            "last": None, "close": None, "bid": None, "ask": None,
            "high": None, "low": None, "time": None,
        }
    if not t:
        _cache_write(cache_key, out)
        return out
    out = {
        "conId": getattr(t.contract, "conId", None),
        "symbol": getattr(t.contract, "localSymbol", None) or t.contract.symbol,
        "last": _num_or_none(t.last),
        "close": _num_or_none(t.close),
        "bid": _num_or_none(t.bid),
        "ask": _num_or_none(t.ask),
        "high": _num_or_none(t.high),
        "low": _num_or_none(t.low),
        "time": util.formatIBDatetime(t.time) if getattr(t, "time", None) else None,
    }
    _cache_write(cache_key, out)
    return out

# --- intraday/period history (bars) ----------------------------------------
@router.get("/history")
async def history(
    symbol: str | None = None,
    conId: int | None = None,
    secType: str | None = None,
    exchange: str | None = None,
    currency: str | None = None,
    duration: str = "1 D",
    barSize: str = "5 mins",
    what: str = "TRADES",
    useRTH: bool = True,
):
    cache_key = "hist-" + _safe_name(f"{conId or symbol}-{secType or 'STK'}-{duration}-{barSize}-{what}-{int(useRTH)}") + ".json"
    try:
        await _ensure_connected()
    except Exception as e:
        cached = _cache_read(cache_key, None)
        if cached is not None:
            return cached
        raise HTTPException(503, f"IBKR offline and no history cache: {e}")
    c = _mk_contract(symbol, conId, exchange, secType, currency)
    if conId and (not getattr(c, "exchange", None) or not getattr(c, "currency", None)):
        try:
            [c] = await ib.qualifyContractsAsync(c)
        except Exception:
            pass
    try:
        bars: list[BarData] = await ib.reqHistoricalDataAsync(
            c,
            endDateTime="",
            durationStr=duration,
            barSizeSetting=barSize,
            whatToShow=what,
            useRTH=useRTH,
            formatDate=2,
            keepUpToDate=False,
        )
    except Exception as e:
        raise HTTPException(502, detail=f"history failed: {e!s}")
    out = {
        "contract": {
            "conId": getattr(c, "conId", None),
            "symbol": getattr(c, "localSymbol", None) or getattr(c, "symbol", None),
            "secType": c.secType,
            "currency": c.currency,
        },
        "bars": [{"t": b.date, "o": b.open, "h": b.high, "l": b.low, "c": b.close, "v": b.volume} for b in bars],
    }
    _cache_write(cache_key, out)
    return out

# --- PnL for a single contract --------------------------------------------
@router.get("/pnl/single")
async def pnl_single(conId: int):
    cache_key = f"pnl-{int(conId)}.json"
    try:
        await _ensure_connected()
        account = await _account_code()
        pnl = await ib.reqPnLSingleAsync(account, "", conId)
        out = {
            "conId": conId,
            "daily": getattr(pnl, "dailyPnL", 0) or 0,
            "unrealized": getattr(pnl, "unrealizedPnL", 0) or 0,
            "realized": getattr(pnl, "realizedPnL", 0) or 0,
        }
        _cache_write(cache_key, out)
        return out
    except Exception as e:
        cached = _cache_read(cache_key, None)
        if cached is not None:
            return cached
        return {
        "conId": conId,
        "daily": 0, "unrealized": 0, "realized": 0
    }

# --- Portfolio spark by summing USD positions ------------------------------
@router.get("/portfolio/spark")
async def portfolio_spark(duration: str = "1 D", barSize: str = "5 mins"):
    """
    Build a quick equity series by summing close*position for USD positions.
    (FX/derivatives multipliers, non-USD CCY are skipped for brevity.)
    """
    cache_key = f"portfolio_spark-{_safe_name(duration)}-{_safe_name(barSize)}.json"
    try:
        await _ensure_connected()
    except Exception as e:
        cached = _cache_read(cache_key, None)
        if cached is not None:
            return cached
        return {"points": [], "note": "offline and no cache"}
    # mirror /positions robustness
    try:
        if hasattr(ib, "reqPositionsAsync"):
            pos = await ib.reqPositionsAsync()
        else:
            ib.reqPositions()
            await asyncio.sleep(1.0)
            pos = list(ib.positions())
    finally:
        try: ib.cancelPositions()
        except Exception: pass
    usd = [p for p in pos if (p.contract.currency or "USD") == "USD"]
    if not usd:
        return {"points": [], "note": "no USD positions"}
    # fetch bars per conId and align by index
    series = []
    for p in usd:
        bars = await ib.reqHistoricalDataAsync(
            p.contract, endDateTime="", durationStr=duration, barSizeSetting=barSize,
            whatToShow="TRADES", useRTH=True, formatDate=2
        )
        series.append([ (b.date.timestamp() if hasattr(b.date, "timestamp") else util.parseIBDatetime(b.date).timestamp(), b.close * p.position) for b in bars ])
    # align by index position (IB returns same count for same params typically)
    length = min(len(s) for s in series)
    if length == 0:
        return {"points": [], "note": "no bars"}
    points = []
    for i in range(length):
        ts = series[0][i][0]
        total = sum(s[i][1] for s in series if len(s) > i)
        points.append([ts, float(total)])
    out = {"points": points}
    _cache_write(cache_key, out)
    return out
    
# --- PnL summary (aggregate across all current positions) -------------------
@router.get("/pnl/summary")
async def pnl_summary():
    cache_key = "pnl_summary.json"
    try:
        await _ensure_connected()
        account = await _account_code()
        try:
            if hasattr(ib, "reqPositionsAsync"):
                pos = await ib.reqPositionsAsync()
            else:
                ib.reqPositions()
                await asyncio.sleep(1.0)
                pos = list(ib.positions())
        finally:
            try: ib.cancelPositions()
            except Exception: pass
        total_realized = 0.0
        total_unrealized = 0.0
        for p in pos or []:
            try:
                pnl = await ib.reqPnLSingleAsync(account, "", int(p.contract.conId))
                total_realized += float(getattr(pnl, "realizedPnL", 0) or 0)
                total_unrealized += float(getattr(pnl, "unrealizedPnL", 0) or 0)
            except Exception:
                continue
        out = {"realized": total_realized, "unrealized": total_unrealized}
        _cache_write(cache_key, out)
        return out
    except Exception as e:
        cached = _cache_read(cache_key, None)
        if cached is not None:
            return cached
        return {"realized": 0.0, "unrealized": 0.0}
    
# --- place / cancel ---------------------------------------------------------
@router.post("/orders/place")
async def orders_place(payload: dict = Body(...)):
    """
    Place a market/limit order.
    Body keys: symbol|conId, secType, exchange, currency, side (BUY/SELL),
               type (MKT/LMT), qty, limitPrice, tif (DAY/GTC)
    """
    await _ensure_connected()
    conId    = payload.get("conId")
    symbol   = payload.get("symbol")
    secType  = payload.get("secType", "STK")
    exchange = payload.get("exchange", "SMART")
    currency = payload.get("currency", "USD")
    side     = (payload.get("side") or "BUY").upper()
    typ      = (payload.get("type") or "MKT").upper()
    qty      = float(payload.get("qty", 0))
    tif      = payload.get("tif", "DAY")
    limit    = payload.get("limitPrice")
    if (not conId and not symbol) or qty <= 0:
        raise HTTPException(400, "symbol/conId and qty required")
    # basic guards
    if typ not in ("MKT", "LMT"):
        raise HTTPException(400, f"unsupported order type {typ}")
    if tif not in ("DAY", "GTC", "IOC"):
        raise HTTPException(400, f"unsupported TIF {tif}")

    c = Contract(conId=int(conId)) if conId else await _resolve_contract(symbol, secType, exchange, currency)
    c = await _qualify(c)
    try:
        if typ == "LMT":
            if limit is None:
                raise HTTPException(400, "limitPrice required for LMT")
            order: Order = LimitOrder(side, qty, float(limit), tif=tif)
        else:
            order = MarketOrder(side, qty, tif=tif)

        trade = ib.placeOrder(c, order)
        # attach live listener so clients on /orders/stream get push updates
        _attach_trade_listener(trade)
        st = await _await_status(trade)
    except Exception as e:
        log.exception("place order failed")
        raise HTTPException(502, detail=f"IBKR place failed: {e!s}")
    _log_order("place", {
        "symbol": symbol, "conId": getattr(c, "conId", None), "side": side,
        "type": typ, "qty": qty, "limitPrice": limit, "tif": tif,
        "orderId": getattr(trade.order, "orderId", None),
        "permId": getattr(trade.order, "permId", None),
        "status": getattr(st, "status", None) if st else None,
    })
    return {
        "orderId": getattr(trade.order, "orderId", None),
        "permId": getattr(trade.order, "permId", None),
        "status": getattr(st, "status", None) if st else None,
        "filled": getattr(st, "filled", None) if st else None,
        "remaining": getattr(st, "remaining", None) if st else None,
    }
    
@router.post("/orders/bracket")
async def orders_bracket(payload: dict = Body(...)):
    """
    Place a parent order with attached TP and SL (OCO).
    Body:
      symbol|conId, side(BUY/SELL), qty,
      entryType (MKT|LMT), limitPrice (if LMT),
      takeProfit (abs price), stopLoss (abs price), tif (DAY/GTC)
    """
    await _ensure_connected()
    conId    = payload.get("conId")
    symbol   = payload.get("symbol")
    side     = (payload.get("side") or "BUY").upper()
    qty      = float(payload.get("qty", 0))
    entryType= (payload.get("entryType") or "LMT").upper()
    lmt      = payload.get("limitPrice")
    tp_px    = float(payload.get("takeProfit", 0) or 0)
    sl_px    = float(payload.get("stopLoss", 0) or 0)
    tif      = (payload.get("tif") or "DAY").upper()
    if (not conId and not symbol) or qty <= 0:
        raise HTTPException(400, "symbol/conId and qty required")
    if entryType == "LMT" and lmt is None:
        raise HTTPException(400, "limitPrice required for LMT")
    if tp_px <= 0 or sl_px <= 0:
        raise HTTPException(400, "takeProfit and stopLoss absolute prices required")
    c = Contract(conId=int(conId)) if conId else await _resolve_contract(symbol)
    c = await _qualify(c)
    parent = LimitOrder(side, qty, float(lmt)) if entryType == "LMT" else MarketOrder(side, qty)
    parent.tif = tif
    parent.transmit = False
    # children
    tp = Order()
    tp.action = "SELL" if side == "BUY" else "BUY"
    tp.orderType = "LMT"
    tp.lmtPrice = float(tp_px)
    tp.totalQuantity = qty
    tp.tif = tif
    tp.transmit = False
    sl = Order()
    sl.action = "SELL" if side == "BUY" else "BUY"
    sl.orderType = "STP"
    sl.auxPrice = float(sl_px)
    sl.totalQuantity = qty
    sl.tif = tif
    sl.transmit = True  # last leg transmits the whole OCO
    # OCA group to ensure mutual cancel
    oca = f"OCA-{int(time.time())}-{getattr(c,'conId',0)}"
    for o in (tp, sl):
        o.ocaGroup = oca
        o.ocaType = 1
    # send
    ptrade = ib.placeOrder(c, parent)
    # push updates for parent
    _attach_trade_listener(ptrade)
    pst = await _await_status(ptrade)
    pid = getattr(ptrade.order, "orderId", None)
    if pid is None:
        raise HTTPException(502, "Parent orderId missing")
    tp.parentId = pid
    sl.parentId = pid
    t1 = ib.placeOrder(c, tp)
    t2 = ib.placeOrder(c, sl)
    # push updates for children
    _attach_trade_listener(t1)
    _attach_trade_listener(t2)
    st1 = await _await_status(t1)
    st2 = await _await_status(t2)
    _log_order("bracket", {
        "symbol": symbol, "conId": getattr(c, "conId", None), "side": side,
        "qty": qty, "entryType": entryType, "limitPrice": lmt,
        "tp": tp_px, "sl": sl_px, "parentId": pid,
        "parentStatus": getattr(pst, "status", None),
        "tpStatus": getattr(st1, "status", None),
        "slStatus": getattr(st2, "status", None),
    })
    return {
        "parentId": pid,
        "ocaGroup": oca,
        "parentStatus": getattr(pst, "status", None),
        "tpStatus": getattr(st1, "status", None),
        "slStatus": getattr(st2, "status", None),
    }

@router.post("/orders/cancel")
async def orders_cancel(payload: dict = Body(...)):
    await _ensure_connected()
    oid = payload.get("orderId")
    if oid is None:
        raise HTTPException(400, "orderId required")
    tr = next((t for t in ib.trades() if getattr(t.order, "orderId", None) == int(oid)), None)
    if not tr:
        raise HTTPException(404, f"order {oid} not found")
    ib.cancelOrder(tr.order)
    _log_order("cancel", {"orderId": int(oid)})
    return {"ok": True}

# --- modify (cancel+place) --------------------------------------------------
@router.post("/orders/replace")
async def orders_replace(payload: dict = Body(...)):
    """
    Simple modify: cancel old orderId then place a new order with given fields.
    Reuses the /orders/place semantics for keys.
    """
    await _ensure_connected()
    old = payload.get("orderId")
    if old is None:
        raise HTTPException(400, "orderId required")
    # cancel old
    for t in ib.trades():
        if getattr(t.order, "orderId", None) == int(old):
            ib.cancelOrder(t.order)
            break
    # strip and place new
    payload = {k: v for k, v in payload.items() if k != "orderId"}
    # inline "place" (Market/Limit) to avoid route duplication
    conId    = payload.get("conId")
    symbol   = payload.get("symbol")
    secType  = payload.get("secType", "STK")
    exchange = payload.get("exchange", "SMART")
    currency = payload.get("currency", "USD")
    side     = (payload.get("side") or "BUY").upper()
    typ      = (payload.get("type") or "MKT").upper()
    qty      = float(payload.get("qty", 0))
    tif      = payload.get("tif", "DAY")
    limit    = payload.get("limitPrice")
    if (not conId and not symbol) or qty <= 0:
        raise HTTPException(400, "symbol/conId and qty required")
    c = Contract(conId=int(conId)) if conId else await _resolve_contract(symbol, secType, exchange, currency)
    c = await _qualify(c)
    if typ == "LMT":
        if limit is None:
            raise HTTPException(400, "limitPrice required for LMT")
        order: Order = LimitOrder(side, qty, float(limit), tif=tif)
    else:
        order = MarketOrder(side, qty, tif=tif)
    trade = ib.placeOrder(c, order)
    # push updates for the replacement order as well
    _attach_trade_listener(trade)
    st = await _await_status(trade)
    _log_order("replace", {
        "oldOrderId": int(old), "symbol": symbol, "conId": getattr(c, "conId", None),
        "side": side, "type": typ, "qty": qty, "limitPrice": limit, "tif": tif,
        "orderId": getattr(trade.order, "orderId", None),
        "permId": getattr(trade.order, "permId", None),
        "status": getattr(st, "status", None) if st else None,
    })
    return {
        "ok": True,
        "orderId": getattr(trade.order, "orderId", None),
        "permId": getattr(trade.order, "permId", None),
        "status": getattr(st, "status", None) if st else None,
    }
