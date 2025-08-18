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
                "position": float(p.position),
                "avgCost": float(p.avgCost),
            })
        except Exception:
            # Skip malformed rows instead of failing the whole endpoint
            import logging; logging.getLogger("ibkr").exception("normalize position row")
            continue
    return out
