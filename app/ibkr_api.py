# app/ibkr_api.py
from __future__ import annotations
import os, math, logging
from fastapi import APIRouter, HTTPException
from ib_insync import IB, util

router = APIRouter(prefix="/ibkr", tags=["ibkr"])
log = logging.getLogger("ibkr")

IB_HOST = os.getenv("IB_HOST", "127.0.0.1")
# Live by default; override with IB_PORT if you want paper (4002)
IB_PORT = int(os.getenv("IB_PORT", "4001"))
IB_CLIENT_ID = int(os.getenv("IB_CLIENT_ID", "11"))

ib = IB()

async def _ensure_connected():
    if ib.isConnected():
        return
    try:
        await ib.connectAsync(IB_HOST, IB_PORT, clientId=IB_CLIENT_ID, timeout=4)
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"IBKR connect failed: {e!s}")

def _num_or_none(x):
    """Return float if finite; otherwise None so JSON stays valid."""
    if x is None:
        return None
    try:
        v = float(x)
        return v if math.isfinite(v) else None
    except Exception:
        return None

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
    try:
        pos = await ib.positionsAsync()
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"positionsAsync failed: {e!s}")

    out = []
    for p in pos:
        try:
            c = p.contract
            # Some contracts miss localSymbol/primaryExchange
            symbol   = _safe_get(c, "localSymbol") or _safe_get(c, "symbol") or str(_safe_get(c, "conId", ""))
            secType  = _safe_get(c, "secType")
            currency = _safe_get(c, "currency")
            exchange = _safe_get(c, "primaryExchange") or _safe_get(c, "exchange")
            out.append({
                "account": p.account,
                "symbol": symbol,
                "secType": secType,
                "currency": currency,
                "exchange": exchange,
                "position": _num_or_none(p.position),
                "avgCost": _num_or_none(p.avgCost),
            })
        except Exception:
            # Log and skip any weird row rather than 500 the whole endpoint
            log.exception("Failed to normalize IBKR position row")
            continue
    return out
