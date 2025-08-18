# app/ibkr_api.py
from __future__ import annotations
import os, math, logging, json, time
from pathlib import Path
from fastapi import APIRouter, HTTPException, Body, Query
from ib_insync import IB, util, Stock, Forex, Future, Contract, Order, MarketOrder, LimitOrder, BarData


router = APIRouter(prefix="/ibkr", tags=["ibkr"])
log = logging.getLogger("ibkr")

IB_HOST = os.getenv("IB_HOST", "127.0.0.1")
IB_PORT = int(os.getenv("IB_PORT", "4002"))
IB_CLIENT_ID = int(os.getenv("IB_CLIENT_ID", "11"))

ib = IB()
RUNTIME = Path(os.getenv("TB_RUNTIME_DIR", Path(__file__).resolve().parent.parent / "runtime"))
RUNTIME.mkdir(parents=True, exist_ok=True)
ORDERS_LOG = RUNTIME / "orders.log"

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

@router.get("/positions")
async def positions():
    await _ensure_connected()

    # Prefer modern coroutine API; fall back to legacy stream API.
    try:
        if hasattr(ib, "reqPositionsAsync"):
            pos = await ib.reqPositionsAsync()
        else:
            ib.reqPositions()
            await ib.sleep(1.0)  # brief window to collect snapshots
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
    trades = list(ib.openTrades())
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
    q = (q or query or "").strip()
    if not q:
        return []
    # fast symbol search
    syms = await ib.reqMatchingSymbolsAsync(q)
    out = []
    for s in syms:
        # pick the 'best' contract description
        for desc in s.contractDescriptions or []:
            c = desc.contract
            out.append({
                "symbol": s.symbol,
                "name": s.description,
                "secType": c.secType,
                "conId": c.conId,
                "currency": c.currency,
                "exchange": c.primaryExchange or c.exchange or "SMART",
            })
    # de-dup by conId
    seen, uniq = set(), []
    for d in out:
        cid = d.get("conId")
        if cid in seen: continue
        seen.add(cid); uniq.append(d)
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
    [t] = await ib.reqTickersAsync(c)
    md = t.marketPrice()
    return {
        "conId": getattr(t.contract, "conId", None),
        "symbol": getattr(t.contract, "localSymbol", None) or t.contract.symbol,
        "last": t.last,
        "close": t.close,
        "bid": t.bid,
        "ask": t.ask,
        "high": t.high,
        "low": t.low,
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
            await ib.sleep(1.0)
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
            await ib.sleep(1.0)
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
    c = Contract(conId=int(conId)) if conId else await _resolve_contract(symbol, secType, exchange, currency)
    if typ == "LMT":
        if limit is None:
            raise HTTPException(400, "limitPrice required for LMT")
        order: Order = LimitOrder(side, qty, float(limit), tif=tif)
    else:
        order = MarketOrder(side, qty, tif=tif)
    trade = ib.placeOrder(c, order)
    await ib.sleep(0.5)
    _log_order("place", {
        "symbol": symbol, "conId": getattr(c, "conId", None), "side": side,
        "type": typ, "qty": qty, "limitPrice": limit, "tif": tif,
        "orderId": getattr(trade.order, "orderId", None), "permId": getattr(trade.order, "permId", None)
    })
    return {"orderId": trade.order.orderId, "permId": trade.order.permId}

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
    await ib.sleep(0.5)
    _log_order("replace", {
        "oldOrderId": int(old), "symbol": symbol, "conId": getattr(c, "conId", None),
        "side": side, "type": typ, "qty": qty, "limitPrice": limit, "tif": tif,
        "orderId": getattr(trade.order, "orderId", None), "permId": getattr(trade.order, "permId", None)
    })
    return {"ok": True, "orderId": trade.order.orderId, "permId": trade.order.permId}
