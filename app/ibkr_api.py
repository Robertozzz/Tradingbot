# app/ibkr_api.py
from __future__ import annotations
import os
from fastapi import APIRouter, HTTPException
from ib_insync import IB, util

router = APIRouter(prefix="/ibkr", tags=["ibkr"])

IB_HOST = os.getenv("IB_HOST", "127.0.0.1")
IB_PORT = int(os.getenv("IB_PORT", "4002"))  # paper by default
IB_CLIENT_ID = int(os.getenv("IB_CLIENT_ID", "11"))

ib = IB()

async def _ensure_connected():
    if ib.isConnected():
        return
    try:
        await ib.connectAsync(IB_HOST, IB_PORT, clientId=IB_CLIENT_ID, timeout=4)
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"IBKR connect failed: {e!s}")

@router.get("/ping")
async def ping():
    await _ensure_connected()
    # server time proves the API session is alive
    dt = await ib.reqCurrentTimeAsync()
    return {"connected": ib.isConnected(), "server_time": dt.isoformat()}

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
    pos = await ib.positionsAsync()
    return [
        {
            "account": p.account,
            "symbol": (p.contract.localSymbol or p.contract.symbol),
            "secType": p.contract.secType,
            "currency": p.contract.currency,
            "exchange": p.contract.exchange,
            "position": p.position,
            "avgCost": p.avgCost,
        }
        for p in pos
    ]
