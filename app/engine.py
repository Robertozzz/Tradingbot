
from __future__ import annotations

import asyncio
import json
import time
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List
import os

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

# Where the web server reads its snapshot (/api/bootstrap, /sse/updates)
RUNTIME = Path("./runtime")
RUNTIME.mkdir(parents=True, exist_ok=True)
STATE_FP = RUNTIME / "state.json"
STATUS_FP = RUNTIME / "status.json"   # optional: written by your watchdog/IBKR process

def _write_atomic(fp: Path, text: str) -> None:
    """Atomic write: prevents readers from seeing partial files."""
    tmp = fp.with_suffix(fp.suffix + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    os.replace(tmp, fp)

def _read_health() -> Dict[str, Any]:
    """
    Non-blocking health read. Expected (but optional) shape:
      { "ibkr": { "online": true, ... }, ... }
    """
    try:
        if STATUS_FP.exists():
            data = json.loads(STATUS_FP.read_text(encoding="utf-8"))
            ibkr_online = False
            # try a few common layouts
            if isinstance(data, dict):
                if "ibkr" in data and isinstance(data["ibkr"], dict):
                    ibkr_online = bool(data["ibkr"].get("online") or data["ibkr"].get("connected"))
                elif "health" in data and isinstance(data["health"], dict):
                    ibkr_online = bool(data["health"].get("ibkr"))
            return {"ibkr": ibkr_online}
    except Exception:
        pass
    return {"ibkr": False}

def _normalize_series(vals: List[float]) -> List[float]:
    if not vals:
        return []
    lo, hi = min(vals), max(vals)
    if hi <= lo:
        return [0.5 for _ in vals]
    return [(v - lo) / (hi - lo) for v in vals]

def _compute_sparks_from_history(history_dir: Path, symbols: List[str], max_points: int = 60) -> Dict[str, List[float]]:
    """
    Build per-symbol normalized spark arrays from recent history files.
    History files are written by export_assets() as exports/history/assets-YYYYMMDDTHHMMSSZ.json
    """
    out: Dict[str, List[float]] = {s: [] for s in symbols}
    try:
        files = sorted(history_dir.glob("assets-*.json"), key=lambda p: p.stat().st_mtime)[-max_points:]
        # Build chronological series of USD per symbol
        for fp in files:
            try:
                j = json.loads(fp.read_text(encoding="utf-8"))
                arr = j.get("assets") or []
                # map symbol -> usd at this snapshot
                snap_map = {str(a.get("symbol", "")).upper(): float(a.get("usd", 0.0) or 0.0) for a in arr}
                for s in symbols:
                    out[s].append(float(snap_map.get(s, 0.0)))
            except Exception:
                # skip broken snapshot; keep going
                pass
        # Normalize to 0..1 for UI
        for s, series in list(out.items()):
            out[s] = _normalize_series(series)
    except Exception:
        pass
    return out

async def export_accounts(session) -> None:
    if Account is None:
        return []
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
    # Keep legacy export for debugging/inspection
    (EXPORTS / "accounts.json").write_text(json.dumps({"accounts": out}, indent=2))
    return out

async def export_assets(session) -> None:
    # Aggregate Balance rows to asset-level
    if Balance is None:
        return []
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
    return rows

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
                accounts = await export_accounts(session)
                assets = await export_assets(session)
                for p in await fetch_pending_plans(session):
                    await process_plan(session, p)
                await session.commit()
                # ---- Build UI snapshot for /api/bootstrap + /sse/updates ----
                symbols = [str(a.get("symbol","")).upper() for a in (assets or [])][:50]
                sparks = _compute_sparks_from_history(HIST, symbols, max_points=60)
                snap = {
                    "ts": int(time.time()),
                    "updated_iso": datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
                    "health": _read_health(),
                    "accounts": accounts or [],
                    "assets": assets or [],
                    "sparks": sparks,  # symbol -> [0..1] series (may be empty initially)
                }
                # Write atomically so web readers never see partial JSON
                _write_atomic(STATE_FP, json.dumps(snap, separators=(",", ":"), ensure_ascii=False))

            except Exception as e:
                # You can log this to logs/engine.log
                pass
        await asyncio.sleep(interval)

if __name__ == "__main__":
    asyncio.run(engine_loop())
