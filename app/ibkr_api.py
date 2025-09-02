# app/ibkr_api.py
from __future__ import annotations
import os, math, logging, json, time
from pathlib import Path
from fastapi import APIRouter, HTTPException, Body, Query
import subprocess, shlex
import re
from fastapi.responses import StreamingResponse
from ib_insync import IB, util, Stock, Forex, Future, Contract, Order, MarketOrder, LimitOrder, BarData # type: ignore
from typing import Any, Callable
import asyncio
from collections import defaultdict, deque
from datetime import datetime, timezone
from fastapi import Request

# Router must be created before any @router.get/post decorators
router = APIRouter(prefix="/ibkr", tags=["ibkr"])
log = logging.getLogger("ibkr")

# systemd unit names from installer (split model: Xpra session + IBC runner)
IBC_XPRA_SERVICE = "xpra-ibgateway-main.service"
IBC_RUNNER_SERVICE = IBC_XPRA_SERVICE  # single-unit model

IB_HOST = os.getenv("IB_HOST", "127.0.0.1")
IB_CLIENT_ID = int(os.getenv("IB_CLIENT_ID", "11"))
IBC_INI_PATH = Path("/opt/tradingbot/runtime/ibc.ini")

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

# ----- lookup helpers: aliases + local universe ------------------------------
# Built-in name aliases that users type vs. official names.
# You can extend/override by creating runtime/aliases.json as
# { "google": ["alphabet","GOOGL","GOOG"], ... }
ALIASES_DEFAULT: dict[str, list[str]] = {
    "google": ["alphabet", "GOOGL", "GOOG"],
    "alphabet": ["GOOGL", "GOOG"],
    "facebook": ["meta", "META"],
    "meta": ["META", "facebook"],
    "berkshire": ["BRK.A", "BRK.B", "Berkshire Hathaway"],
    "sq": ["block", "Square", "SQ"],
    "square": ["block", "SQ"],
    "block": ["SQ"],
    "x": ["twitter", "TWTR"],  # legacy; harmless if not present
    "apple": ["AAPL", "Apple Inc"],
    "microsoft": ["MSFT", "Microsoft Corporation"],
    "amazon": ["AMZN", "Amazon.com"],
    "nvidia": ["NVDA", "NVIDIA"],
    "tesla": ["TSLA", "Tesla"],
    "fugro": ["FUR", "Fugro N.V."],
}
ALIASES_PATH = RUNTIME / "aliases.json"
_ALIASES: dict[str, list[str]] | None = None

def _aliases() -> dict[str, list[str]]:
    global _ALIASES
    if _ALIASES is not None:
        return _ALIASES
    data = ALIASES_DEFAULT.copy()
    try:
        if ALIASES_PATH.exists():
            user = json.loads(ALIASES_PATH.read_text(encoding="utf-8"))
            if isinstance(user, dict):
                for k, v in user.items():
                    if isinstance(k, str):
                        vv = [str(x) for x in (v or [])] if isinstance(v, list) else []
                        data[k.lower()] = vv
    except Exception:
        pass
    _ALIASES = data
    return data

# Optional local universe file (list of dicts with symbol/name/secType/etc.)
UNIVERSE_PATHS = [
    RUNTIME / "universe.json",
    Path("/opt/tradingbot/static/universe.json"),
]
_UNIVERSE: list[dict] | None = None

def _universe() -> list[dict]:
    global _UNIVERSE
    if _UNIVERSE is not None:
        return _UNIVERSE
    # minimal seed so name searches work out-of-the-box offline
    seed = [
        {"symbol":"AAPL","name":"Apple Inc","secType":"STK","exchange":"SMART","currency":"USD"},
        {"symbol":"MSFT","name":"Microsoft Corporation","secType":"STK","exchange":"SMART","currency":"USD"},
        {"symbol":"AMZN","name":"Amazon.com, Inc.","secType":"STK","exchange":"SMART","currency":"USD"},
        {"symbol":"NVDA","name":"NVIDIA Corporation","secType":"STK","exchange":"SMART","currency":"USD"},
        {"symbol":"GOOGL","name":"Alphabet Inc. Class A","secType":"STK","exchange":"SMART","currency":"USD"},
        {"symbol":"GOOG","name":"Alphabet Inc. Class C","secType":"STK","exchange":"SMART","currency":"USD"},
        {"symbol":"META","name":"Meta Platforms, Inc.","secType":"STK","exchange":"SMART","currency":"USD"},
        {"symbol":"TSLA","name":"Tesla, Inc.","secType":"STK","exchange":"SMART","currency":"USD"},
        {"symbol":"BRK.B","name":"Berkshire Hathaway Inc. Class B","secType":"STK","exchange":"SMART","currency":"USD"},
    ]
    for p in UNIVERSE_PATHS:
        try:
            if p.exists():
                arr = json.loads(p.read_text(encoding="utf-8"))
                if isinstance(arr, list):
                    seed.extend([x for x in arr if isinstance(x, dict)])
                    break
        except Exception:
            pass
    # de-dupe by (symbol, exchange)
    seen = set()
    uniq = []
    for r in seed:
        key = (str(r.get("symbol","")).upper(), str(r.get("exchange","SMART")).upper())
        if key in seen: continue
        seen.add(key); uniq.append(r)
    _UNIVERSE = uniq
    return _UNIVERSE

def _alias_variants(term: str) -> list[str]:
    t = (term or "").strip()
    if not t:
        return []
    lower = t.lower()
    out = [t]
    al = _aliases()
    if lower in al:
        out.extend(al[lower])
    # compact token (remove spaces/punct) helps “BerkshireHathaway”
    compact = re.sub(r"[^A-Za-z0-9]+", "", t)
    if compact and compact != t:
        out.append(compact)
    # tokens
    toks = [x for x in re.split(r"[^A-Za-z0-9]+", t) if len(x) >= 3]
    out.extend(toks)
    # unique, preserve order
    seen=set(); uniq=[x for x in out if not (x.lower() in seen or seen.add(x.lower()))]
    return uniq

def _name_prefix_variants(term: str, min_len: int = 3, max_per_word: int = 4) -> list[str]:
    """
    For human-ish names (not tickers), return short prefixes of each word.
    Example: 'Manhattan Associates' -> ['man','manh','manha','assoc','asso','ass']
    (bounded so we don't spam IB.)
    """
    t = (term or "").strip()
    if not t:
        return []
    words = [w for w in re.split(r"[^A-Za-z]+", t) if len(w) >= min_len]
    out: list[str] = []
    for w in words:
        wl = w.lower()
        upto = min(len(wl), min_len + max_per_word - 1)
        for L in range(min_len, upto + 1):
            out.append(wl[:L])
    # unique, preserve order
    seen = set()
    return [x for x in out if not (x in seen or seen.add(x))]

def _cache_scan_by_name_substring(term: str, limit: int = 30) -> list[dict]:
    """
    Fallback: scan our search cache for rows whose name contains the substring.
    Helps when IB is sluggish and we’ve previously looked up related names.
    """
    tl = (term or "").strip().lower()
    if not tl:
        return []
    cache = _cache_read("search_cache.json", {})
    if not isinstance(cache, dict):
        return []
    out: list[dict] = []
    seen = set()
    for rows in cache.values():
        if not isinstance(rows, list):
            continue
        for r in rows:
            try:
                name = (r.get("name") or r.get("description") or "").lower()
                sym  = (r.get("symbol") or "").upper()
                ex   = (r.get("exchange") or r.get("primaryExchange") or "SMART").upper()
                key  = (r.get("conId") or f"{sym}-{ex}")
                if key in seen:
                    continue
                if tl and tl in name:
                    seen.add(key)
                    out.append(dict(r))
                    if len(out) >= limit:
                        return out
            except Exception:
                continue
    return out

# --- quick heuristics so tickers/FX work even when offline -------------------
_FX3 = {
    "USD","EUR","GBP","JPY","AUD","CAD","CHF","NZD","SEK","NOK","DKK",
    "CNH","CNY","HKD","SGD","MXN","ZAR"
}

def _is_fx_pair(term: str) -> bool:
    t = (term or "").strip().upper()
    if len(t) != 6:  # e.g. EURUSD
        return False
    a, b = t[:3], t[3:]
    return a in _FX3 and b in _FX3 and a != b

def _is_ticker_like(term: str) -> bool:
    """
    Very permissive stock ticker check: letters/digits with optional dot or hyphen,
    length 1..6 for main part (so BRK.B, RDS-A are fine).
    """
    t = (term or "").strip()
    if not t:
        return False
    return re.fullmatch(r"[A-Za-z0-9]{1,6}([.\-][A-Za-z0-9]{1,2})?", t) is not None

async def _collect_from_matching_symbols(syms, qualify_limit: int = 12) -> list[dict]:
    """
    Normalize results from reqMatchingSymbols.
    Qualify only a handful (qualify_limit) to enrich exchange/currency quickly.
    """
    out: list[dict] = []
    to_qualify: list[Contract] = []
    for s in (syms or []):
        for desc in (getattr(s, "contractDescriptions", None) or []):
            c = getattr(desc, "contract", None)
            if not c:
                continue
            row = {
                "symbol": s.symbol or getattr(c, "symbol", None),
                "name": s.description or getattr(c, "localSymbol", None) or getattr(c, "symbol", None),
                "secType": getattr(c, "secType", None) or "STK",
                "conId": int(getattr(c, "conId", 0)) or None,
                "currency": getattr(c, "currency", None) or None,
                "exchange": getattr(c, "primaryExchange", None) or getattr(c, "exchange", None) or None,
                "primaryExchange": getattr(c, "primaryExchange", None) or None,
            }
            # If IB gave us a real contract but exchange/ccy missing, queue for qualify.
            # Prioritize rows missing BOTH and rows whose secType is STK (common case).
            if row["conId"] and (row["exchange"] is None or row["currency"] is None):
                if len(to_qualify) < qualify_limit:
                    to_qualify.append(c)
            out.append(row)
    # qualify a few to enrich metadata
    if to_qualify:
        try:
            qcs = await ib.qualifyContractsAsync(*to_qualify)
            qmap = {qc.conId: qc for qc in (qcs or []) if getattr(qc, "conId", None)}
            for r in out:
                cid = r.get("conId")
                if cid and cid in qmap:
                    qc = qmap[cid]
                    r["currency"] = getattr(qc, "currency", None) or r["currency"]
                    r["exchange"] = getattr(qc, "primaryExchange", None) or getattr(qc, "exchange", None) or r["exchange"]
                    r["primaryExchange"] = getattr(qc, "primaryExchange", None) or r["primaryExchange"]
        except Exception:
            pass
    # Fill sensible defaults for *synthetic/local* rows only.
    # If a row has a conId (came from IB), do not overwrite with fake USD/SMART.
    for r in out:
        if r.get("conId"):
            # keep whatever we learned; leave blanks if IB didn't provide
            continue
        if r["secType"] == "FX" or _is_fx_pair(str(r.get("symbol") or "")):
            r["currency"] = r["currency"] or (str(r.get("symbol") or "USDUSD")[3:])
            r["exchange"] = r["exchange"] or "IDEALPRO"
            r["primaryExchange"] = r["primaryExchange"] or "IDEALPRO"
        else:
            r["currency"] = r["currency"] or "USD"
            r["exchange"] = r["exchange"] or "SMART"
    return out

async def _enrich_names_with_details(rows: list[dict], maxn: int = 6) -> None:
    """
    For rows that have a conId but a weak name (== symbol or empty),
    fetch ContractDetails and fill 'name' from longName/description.
    Mutates rows in place. Best-effort and bounded by maxn.
    """
    # Pick a handful of conIds that look like they need a better name
    need: list[int] = []
    for r in rows:
        cid = r.get("conId")
        if not cid:
            continue
        nm = (r.get("name") or "").strip()
        sym = (r.get("symbol") or "").strip()
        if (not nm) or (nm.upper() == sym.upper()):
            need.append(int(cid))
            if len(need) >= maxn:
                break
    if not need:
        return
    try:
        await _ensure_connected()
    except Exception:
        return
    for cid in need:
        try:
            cds = await ib.reqContractDetailsAsync(Contract(conId=int(cid)))
            if not cds:
                continue
            cd = cds[0]
            long_name = getattr(cd, "longName", None) or getattr(cd, "description", None)
            prim_exch = getattr(cd.contract, "primaryExchange", None) or getattr(cd.contract, "exchange", None)
            for r in rows:
                if r.get("conId") == cid:
                    if long_name and ((r.get("name") or "").strip().upper() in ("", (r.get("symbol") or "").strip().upper())):
                        r["name"] = long_name
                    if prim_exch and not r.get("primaryExchange"):
                        r["primaryExchange"] = prim_exch
        except Exception:
            continue

async def _match_batch(terms: list[str], per_timeout: float = 3.5, overall_timeout: float = 6.5, max_conc: int = 3) -> list[dict]:
    """
    Run reqMatchingSymbols over several variants with bounded concurrency and a global timeout.
    Cancel any stragglers after the deadline.
    """
    results: list[dict] = []
    sem = asyncio.Semaphore(max_conc)
    async def one(term: str):
        async with sem:
            try:
                syms = await asyncio.wait_for(ib.reqMatchingSymbolsAsync(term), timeout=per_timeout)
                rows = await _collect_from_matching_symbols(syms, qualify_limit=6)
                results.extend(rows)
            except Exception:
                return
    tasks = [asyncio.create_task(one(t)) for t in terms]
    try:
        await asyncio.wait(tasks, timeout=overall_timeout)
    finally:
        for t in tasks:
            if not t.done():
                t.cancel()
    return results

async def _try_resolve_many(terms: list[str], secType: str = "STK") -> list[dict]:
    """
    Fast path: try to resolve a few ticker-like variants directly via reqContractDetails.
    Much faster than name matching and yields a conId.
    """
    out: list[dict] = []
    seen = set()
    for t in terms:
        s = (t or "").strip()
        if not s:
            continue
        if not (_is_ticker_like(s) or _is_fx_pair(s.upper())):
            continue
        key = s.upper()
        if key in seen:
            continue
        seen.add(key)
        try:
            st = "FX" if _is_fx_pair(s.upper()) else secType
            ex = "IDEALPRO" if st == "FX" else "SMART"
            # Try common currencies quickly: USD then EUR (helps EU tickers like FUR)
            curs = ["USD"] if st == "FX" else ["USD", "EUR"]
            c = None
            for cur in curs:
                try:
                    c = await asyncio.wait_for(_resolve_contract(s, st, ex, cur), timeout=2.0)
                    break
                except Exception:
                    continue
            if c is None:
                raise RuntimeError("resolve failed")
            out.append({
                "symbol": getattr(c, "localSymbol", None) or getattr(c, "symbol", None) or key,
                "name": getattr(c, "symbol", None) or key,
                "secType": getattr(c, "secType", None) or st,
                "conId": int(getattr(c, "conId", 0)) or None,
                "currency": getattr(c, "currency", None) or (key[3:] if st == "FX" else "USD"),
                "exchange": getattr(c, "primaryExchange", None) or getattr(c, "exchange", None) or ex,
            })
        except Exception:
            continue
    return out

def _heuristic_seed(term: str) -> list[dict]:
    """
    Return a minimal contract row for obvious tickers or FX pairs so the UI
    always shows *something* immediately, even offline.
    """
    t = (term or "").strip().upper()
    out: list[dict] = []
    if _is_fx_pair(t):
        out.append({
            "symbol": t,
            "name": t,
            "secType": "FX",
            "conId": None,
            "currency": t[3:],                 # RHS (EURUSD -> USD)
            "exchange": "IDEALPRO",
            "primaryExchange": "IDEALPRO",
        })
        return out
    if _is_ticker_like(t):
        out.append({
            "symbol": t,
            "name": t,
            "secType": "STK",
            "conId": None,
            "currency": "USD",
            "exchange": "SMART",
            "primaryExchange": "SMART",
        })
    return out

def _local_match(term: str, limit: int = 50) -> list[dict]:
    tl = (term or "").strip().lower()
    if not tl:
        return []
    candidates = _universe()
    vars = _alias_variants(term)
    out: list[dict] = []
    seen = set()
    for v in vars:
        vl = v.lower()
        for r in candidates:
            sym = (r.get("symbol") or "").upper()
            name = (r.get("name") or r.get("description") or "")
            key = (sym, r.get("exchange") or "SMART")
            if key in seen: 
                continue
            if sym == v.upper() or vl in name.lower():
                out.append({
                    "symbol": sym,
                    "name": name or sym,
                    "secType": r.get("secType") or "STK",
                    "conId": r.get("conId"),  # may be None offline
                    "currency": r.get("currency") or "USD",
                    "exchange": r.get("exchange") or "SMART",
                    "primaryExchange": r.get("primaryExchange"),
                })
                seen.add(key)
                if len(out) >= limit:
                    return out
    return out

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
        # Warm-up: some IBGW builds are sluggish immediately after login.
        try:
            # cheap ping
            await ib.reqCurrentTimeAsync()
        except Exception:
            pass
        try:
            # prime symbol matcher so first real call is faster
            await asyncio.wait_for(ib.reqMatchingSymbolsAsync("AAPL"), timeout=3.0)
        except Exception:
            pass
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
    for k in ("IB_USER","IB_PASSWORD","IB_MODE","IB_PORT","DISPLAY"):
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
    log in headlessly after a restart. Only touch keys that exist in the
    factory IBC config: IbLoginId, IbPassword, TradingMode,
    AcceptNonBrokerageAccountWarning, ReadOnlyApi, ReadOnlyLogin.
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
        # Paper-account warning: only auto-accept in paper mode so the API is unblocked
        d["AcceptNonBrokerageAccountWarning"] = "yes" if d.get("TradingMode","paper") == "paper" else "no"

        # Ensure API and login are not read-only (valid factory keys)
        d["ReadOnlyApi"] = "no"
        d["ReadOnlyLogin"] = "no"
        # Safe defaults to avoid blocking dialogs / keep logs & role consistent
        # write back
        body = "\n".join(f"{k}={v}" for k,v in d.items()) + "\n"
        IBC_INI_PATH.write_text(body, encoding="utf-8")
        try:
            # keep group-readable for ibkr user (installer sets www-data:ibkr)
            IBC_INI_PATH.chmod(0o640)
        except Exception:
            pass
    except Exception as e:
        log.exception("Failed updating %s", IBC_INI_PATH)
        raise HTTPException(500, f"Failed to update {IBC_INI_PATH}: {e!s}")

def _sudo(cmd: str) -> subprocess.CompletedProcess:
    # uses sudoers rules from installer
    return subprocess.run(shlex.split(f"sudo {cmd}"),
                          stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE,
                          text=True)

def _restart_ibc_stack(with_xpra: bool = False):
    """
    Restart IBC launcher (and optionally the Xpra session).
    Returns CompletedProcess; raises HTTPException on failure.
    """
    r = _sudo(f"systemctl restart {IBC_RUNNER_SERVICE}")
    if r.returncode != 0:
        raise HTTPException(500, f"restart failed: {r.stderr.strip() or r.stdout.strip()}")
    # single unit already covers Xpra+IBC

# -------- IBC config (credentials/mode) -------------------------------------
@router.get("/ibc/config")
async def ibc_config_get():
    env = _read_ibc_env()
    return {
        "IB_USER": env.get("IB_USER",""),
        "IB_MODE": env.get("IB_MODE","paper"),
        "IB_PORT": env.get("IB_PORT","4002"),
    }

@router.post("/ibc/config")
async def ibc_config_set(payload: dict = Body(...)):
    """
    Body: { user, password, mode('paper'|'live'), restart: bool }
    - Empty password fields do NOT overwrite existing values.
    """
    env = _read_ibc_env()
    user = (payload.get("user") or "").strip()
    pwd  = payload.get("password") or ""
    mode = (payload.get("mode") or env.get("IB_MODE","paper")).lower()
    if user:
        env["IB_USER"] = user
    if pwd != "":
        env["IB_PASSWORD"] = pwd
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
        # Restart the IBC runner so new creds/mode take effect (Xpra can stay up)
        _restart_ibc_stack(with_xpra=False)
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
            await ib.connectAsync(IB_HOST, _current_port(), clientId=IB_CLIENT_ID, timeout=3)
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
    term = (q or query or "").strip()
    if not term:
        return []

    # Try to connect, but don't block: if it fails we use local fallbacks.
    online = True
    try:
        await _ensure_connected()
    except Exception:
        online = False
    # Buckets so we can union later.
    out_online: list[dict] = []
    out_local:  list[dict] = []
    out_seed:   list[dict] = _heuristic_seed(term)

    # Fast path for obvious tickers (AAPL, BRK.B, EURUSD, etc.) and alias-variants
    if online:
        variants_quick: list[str] = [term]
        variants_quick += _alias_variants(term)
        # keep small and unique
        seen_fast = set()
        variants_quick = [v for v in variants_quick if not (v in seen_fast or seen_fast.add(v))][:6]
        out_online.extend(await _try_resolve_many(variants_quick, secType="STK"))

    # Online name matching with aliases + *prefix* variants (freer matching)
    if online and len(out_online) < 10:
        variants: list[str] = []
        variants += [term]
        variants += _alias_variants(term)
        variants += _name_prefix_variants(term)  # <= this is what makes 'Manhattan' hit MANH
        variants += [term.upper(), term.lower(), term.title()]
        # unique, preserve order; keep it tight
        seen_v = set()
        variants = [v for v in variants if not (v in seen_v or seen_v.add(v))][:12]
        # Run the batch; allow a hair more time for name searches
        out_online.extend(await _match_batch(variants, per_timeout=4.5, overall_timeout=9.0, max_conc=3))
 
    # Add local universe/aliases (works offline too).
    out_local = _local_match(term, limit=50)
    # Also, use cache substring fallback to catch prior lookups containing this name
    out_cached = _cache_scan_by_name_substring(term, limit=30)

    # Union: seed (heuristics) + local + cached + online
    out = out_seed + out_local + out_cached + out_online

    # De-dup by (conId) then (symbol, exchange)
    seen: set[int] = set()
    uniq: list[dict] = []
    seen_sym_ex = set()
    for d in out:
        cid = d.get("conId")
        if cid:
            if cid in seen:
                continue
            seen.add(cid)
            uniq.append(d)
        else:
            k = (str(d.get("symbol","")).upper(), str(d.get("exchange","SMART")).upper())
            if k in seen_sym_ex:
                continue
            seen_sym_ex.add(k)
            uniq.append(d)

    # If we have any IBKR-backed row (with conId) for a symbol, drop local
    # rows for the same symbol that don't have a conId (prevents SMART+NASDAQ dupes).
    sym_with_conid = { (r.get("symbol") or "").upper()
                       for r in uniq if r.get("conId") }
    if sym_with_conid:
        uniq = [r for r in uniq
                if r.get("conId") or (r.get("symbol") or "").upper() not in sym_with_conid]

    # Soft-rank: prefer name **starts with** term, then contains term
    tl = term.lower()
    def _rank(r: dict) -> tuple[int,int]:
        nm = (r.get("name","") or "").lower()
        if nm.startswith(tl):  # e.g., "Manhattan Associates"
            return (0, len(nm))
        if tl in nm:
            return (1, len(nm))
        return (2, len(nm))
    uniq.sort(key=_rank)

    # If we have any *real* IB rows at all, drop every heuristic row (conId == None).
    # This removes fake USD/SMART placeholders like the FUGRO row when a real FUR exists.
    if any(r.get("conId") for r in uniq):
        uniq = [r for r in uniq if r.get("conId")]

    # Enrich a few names (e.g., turn "FUR" -> "Fugro N.V.", "GOOGL" -> "Alphabet Inc. Class A")
    if online and uniq:
        try:
            await _enrich_names_with_details(uniq, maxn=6)
        except Exception:
            pass

    # Fallback: try direct resolve if nothing matched online (AAPL/EURUSD)
    if online and not uniq:
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
        if not uniq:
            log.warning("search: no online hits for '%s' (likely timeout/slow gateway); returned heuristics/local", term)

    # cache results under multiple keys (term, alias variants, and result tokens)
    try:
        cache = _cache_read("search_cache.json", {})
        if not isinstance(cache, dict): cache = {}
        keys = set()
        keys.add(term.strip())
        for v in _alias_variants(term):
            keys.add(v)
        # index by symbol and name tokens to make offline contains() hit later
        for r in uniq[:50]:
            sym = (r.get("symbol") or "")
            if sym: keys.add(sym)
            name = (r.get("name") or r.get("description") or "")
            for t in re.split(r"[^A-Za-z0-9]+", str(name)):
                if len(t) >= 3:
                    keys.add(t)
        for k in keys:
            cache[str(k)] = uniq[:50]
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
