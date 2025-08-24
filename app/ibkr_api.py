# app/ibkr_api.py
from __future__ import annotations
import os, math, logging, json, time
from pathlib import Path
from fastapi import APIRouter, HTTPException, Body, Query
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
IB_PORT = int(os.getenv("IB_PORT", "4002"))
IB_CLIENT_ID = int(os.getenv("IB_CLIENT_ID", "11"))

# Make ib_insync safe under ASGI/Jupyter nested loops
try:
    util.patchAsyncio()
except Exception:
    pass
ib = IB()

RUNTIME = Path(os.getenv("TB_RUNTIME_DIR", Path(__file__).resolve().parent.parent / "runtime"))
RUNTIME.mkdir(parents=True, exist_ok=True)
ORDERS_LOG = RUNTIME / "orders.log"

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
        await ib.connectAsync(IB_HOST, IB_PORT, clientId=IB_CLIENT_ID, timeout=4)
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"IBKR connect failed: {e!s}")

def _safe_get(obj, attr, fallback=""):
    return getattr(obj, attr, None) or fallback

@router.get("/ping")
async def ping():
    await _ensure_connected()
    # server time proves the API session is alive
    dt = await ib.reqCurrentTimeAsync()
    return {"connected": ib.isConnected(), "server_time": dt.isoformat()}
    
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
    await _ensure_connected()
    # account summary (NetLiq, Cash, BuyingPower, etc.)
    rows = await ib.accountSummaryAsync()
    out = {}
    for r in rows:
        acct = r.account
        out.setdefault(acct, {})[r.tag] = r.value
    return out
    
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
    await _ensure_connected()

    # Prefer modern coroutine API; fall back to legacy stream API.
    try:
        if hasattr(ib, "reqPositionsAsync"):
            pos = await ib.reqPositionsAsync()
        else:
            ib.reqPositions()
            await asyncio.sleep(1.0)  # brief window to collect snapshots
            pos = list(ib.positions())
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"reqPositions failed: {e!s}")
    finally:
        try:
            ib.cancelPositions()
        except Exception:
            pass

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
            # Skip malformed rows instead of failing the whole endpoint
            import logging; logging.getLogger("ibkr").exception("normalize position row")
            continue
    return out
    
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
    return out

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

# --- search/contracts (find tradables by text) -----------------------------
@router.get("/search")
async def search(q: str | None = Query(None), query: str | None = Query(None)):
    await _ensure_connected()
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
    await _ensure_connected()
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
    if not t:
        return {
            "conId": getattr(c, "conId", None),
            "symbol": getattr(c, "localSymbol", None) or getattr(c, "symbol", None),
            "last": None, "close": None, "bid": None, "ask": None,
            "high": None, "low": None, "time": None,
        }
    return {
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
    await _ensure_connected()
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
    return {
        "contract": {
            "conId": getattr(c, "conId", None),
            "symbol": getattr(c, "localSymbol", None) or getattr(c, "symbol", None),
            "secType": c.secType,
            "currency": c.currency,
        },
        "bars": [{"t": b.date, "o": b.open, "h": b.high, "l": b.low, "c": b.close, "v": b.volume} for b in bars],
    }

# --- PnL for a single contract --------------------------------------------
@router.get("/pnl/single")
async def pnl_single(conId: int):
    await _ensure_connected()
    account = await _account_code()
    pnl = await ib.reqPnLSingleAsync(account, "", conId)
    # immediate snapshot; ib_insync returns a PnLSingle object
    return {
        "conId": conId,
        "daily": getattr(pnl, "dailyPnL", 0) or 0,
        "unrealized": getattr(pnl, "unrealizedPnL", 0) or 0,
        "realized": getattr(pnl, "realizedPnL", 0) or 0,
    }

# --- Portfolio spark by summing USD positions ------------------------------
@router.get("/portfolio/spark")
async def portfolio_spark(duration: str = "1 D", barSize: str = "5 mins"):
    """
    Build a quick equity series by summing close*position for USD positions.
    (FX/derivatives multipliers, non-USD CCY are skipped for brevity.)
    """
    await _ensure_connected()
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
    return {"points": points}
    
# --- PnL summary (aggregate across all current positions) -------------------
@router.get("/pnl/summary")
async def pnl_summary():
    await _ensure_connected()
    account = await _account_code()
    # get positions similar to /positions for robustness
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
    return {"realized": total_realized, "unrealized": total_unrealized}
    
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

    try:
        if typ == "LMT":
            if limit is None:
                raise HTTPException(400, "limitPrice required for LMT")
            order: Order = LimitOrder(side, qty, float(limit), tif=tif)
        else:
            order = MarketOrder(side, qty, tif=tif)

        trade = ib.placeOrder(c, order)
        # Older ib_insync doesn't expose Trade.end(); give IB a short beat
        await asyncio.sleep(0.25)
    except Exception as e:
        log.exception("place order failed")
        raise HTTPException(502, detail=f"IBKR place failed: {e!s}")
    _log_order("place", {
        "symbol": symbol, "conId": getattr(c, "conId", None), "side": side,
        "type": typ, "qty": qty, "limitPrice": limit, "tif": tif,
        "orderId": getattr(trade.order, "orderId", None), "permId": getattr(trade.order, "permId", None)
    })
    return {"orderId": trade.order.orderId, "permId": trade.order.permId}
    
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
    await asyncio.sleep(0.25)
    pid = getattr(ptrade.order, "orderId", None)
    if pid is None:
        raise HTTPException(502, "Parent orderId missing")
    tp.parentId = pid
    sl.parentId = pid
    t1 = ib.placeOrder(c, tp)
    t2 = ib.placeOrder(c, sl)
    await asyncio.sleep(0.25)
    _log_order("bracket", {
        "symbol": symbol, "conId": getattr(c, "conId", None), "side": side,
        "qty": qty, "entryType": entryType, "limitPrice": lmt,
        "tp": tp_px, "sl": sl_px, "parentId": pid
    })
    return {"parentId": pid, "ocaGroup": oca}

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
    if typ == "LMT":
        if limit is None:
            raise HTTPException(400, "limitPrice required for LMT")
        order: Order = LimitOrder(side, qty, float(limit), tif=tif)
    else:
        order = MarketOrder(side, qty, tif=tif)
    trade = ib.placeOrder(c, order)
    await asyncio.sleep(0.25)  # Trade.end() may not be awaitable on older ib_insync
    _log_order("replace", {
        "oldOrderId": int(old), "symbol": symbol, "conId": getattr(c, "conId", None),
        "side": side, "type": typ, "qty": qty, "limitPrice": limit, "tif": tif,
        "orderId": getattr(trade.order, "orderId", None), "permId": getattr(trade.order, "permId", None)
    })
    return {"ok": True, "orderId": trade.order.orderId, "permId": trade.order.permId}
