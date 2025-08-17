
from __future__ import annotations

import asyncio
import json
import time
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List

from sqlalchemy import select
from sqlalchemy.orm import selectinload

# Package-relative imports (Option A)
try:
    from .repository import SessionLocal, init_db
except Exception:  # fallback if run loosely
    from repository import SessionLocal, init_db  # type: ignore

# Import your models; keep flexible names
try:
    from .models import Plan, Account, Balance  # type: ignore
except Exception:
    try:
        from models import Plan, Account, Balance  # type: ignore
    except Exception:
        Plan = Account = Balance = None  # type: ignore

EXPORTS = Path("./exports")
HIST = EXPORTS / "history"
for d in (EXPORTS, HIST):
    d.mkdir(parents=True, exist_ok=True)

async def export_accounts(session) -> None:
    if Account is None:
        return
    res = await session.execute(select(Account).options(selectinload(Account.balances)))
    out = []
    for acc in res.scalars().unique().all():
        balances = getattr(acc, "balances", []) or []
        total_usd = 0.0
        available_usd = 0.0
        bal_rows = []
        for b in balances:
            free = float(getattr(b, "free", 0) or 0)
            locked = float(getattr(b, "locked", 0) or 0)
            qty = free + locked
            price = float(getattr(b, "price", 0) or 0)
            usd = qty * price
            usd_avail = free * price
            total_usd += usd; available_usd += usd_avail
            bal_rows.append({
                "asset": getattr(b, "asset", ""),
                "free": free,
                "locked": locked,
                "quantity": qty,
                "price": price,
                "usd": usd
            })
        out.append({
            "id": getattr(acc, "id", None),
            "name": getattr(acc, "name", "Account"),
            "exchange": getattr(acc, "exchange", "Exchange"),
            "status": getattr(acc, "status", "Active"),
            "total_usd": total_usd,
            "available_usd": available_usd,
            "assets": bal_rows
        })
    (EXPORTS / "accounts.json").write_text(json.dumps({"accounts": out}, indent=2))

async def export_assets(session) -> None:
    # Aggregate Balance rows to asset-level
    if Balance is None:
        return
    res = await session.execute(select(Balance))
    assets: Dict[str, Dict[str, Any]] = {}
    for b in res.scalars().all():
        sym = (getattr(b, "asset", "") or "").upper()
        free = float(getattr(b, "free", 0) or 0)
        locked = float(getattr(b, "locked", 0) or 0)
        qty = free + locked
        price = float(getattr(b, "price", 0) or 0)
        d = assets.setdefault(sym, {"symbol": sym, "quantity": 0.0, "price": price})
        d["quantity"] += qty
        if price: d["price"] = price
    rows: List[Dict[str, Any]] = []
    for sym, d in assets.items():
        usd = float(d.get("quantity",0.0) * d.get("price",0.0))
        rows.append({**d, "usd": usd})
    rows.sort(key=lambda x: (-x["usd"], x["symbol"]))
    (EXPORTS / "assets.json").write_text(json.dumps({"assets": rows}, indent=2))
    # Write a rolling snapshot for sparklines
    ts = datetime.utcnow().strftime("%Y%m%dT%H%M%SZ")
    snap_path = HIST / f"assets-{ts}.json"
    try:
        snap_path.write_text(json.dumps({"assets": rows}, indent=2))
    except Exception:
        pass

async def fetch_pending_plans(session):
    if Plan is None:
        return []
    res = await session.execute(
        select(Plan).where(Plan.status.in_(["pending","created","running"])).options(
            selectinload(Plan.entries) if hasattr(Plan, "entries") else ()
        )
    )
    return res.scalars().unique().all()

async def process_plan(session, plan):
    # Stub: iterate entries safely; fill in with your real execution
    if hasattr(plan, "entries"):
        for e in list(plan.entries or []):
            pass
    if hasattr(plan, "status"):
        plan.status = "done"
        await session.commit()

async def engine_loop(interval: float = 10.0):
    await init_db()
    while True:
        async with SessionLocal() as session:
            try:
                await export_accounts(session)
                await export_assets(session)
                for p in await fetch_pending_plans(session):
                    await process_plan(session, p)
                await session.commit()
            except Exception as e:
                # You can log this to logs/engine.log
                pass
        await asyncio.sleep(interval)

if __name__ == "__main__":
    asyncio.run(engine_loop())
