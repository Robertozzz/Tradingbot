
from __future__ import annotations

import asyncio
import json
import time
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List
import os
import http.client
from urllib.parse import urlparse

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
CACHE_DIR = RUNTIME / "cache"
CACHE_DIR.mkdir(parents=True, exist_ok=True)

# at top, reuse CACHE_DIR from above or compute same runtime path
PRETTY_NAMES = CACHE_DIR / "pretty_names.json"

def _read_pretty_names() -> dict:
    try:
        if PRETTY_NAMES.exists():
            j = json.loads(PRETTY_NAMES.read_text(encoding="utf-8"))
            return j if isinstance(j, dict) else {}
    except Exception:
        pass
    return {}

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

def _read_positions_cache() -> list[dict]:
    """Read last-known IBKR positions written by ibkr_api (/runtime/cache/positions.json)."""
    try:
        p = CACHE_DIR / "positions.json"
        if p.exists():
            j = json.loads(p.read_text(encoding="utf-8"))
            return j if isinstance(j, list) else []
    except Exception:
        pass
    return []

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

def _read_json_file(fp: Path, default):
    try:
        if fp.exists():
            return json.loads(fp.read_text(encoding="utf-8"))
    except Exception:
        pass
    return default

def _http_json_get(url: str, timeout: float = 2.5):
    """
    Tiny, dependency-free GET for localhost-only fallbacks.
    Returns parsed JSON or None on failure.
    """
    try:
        u = urlparse(url)
        conn = http.client.HTTPConnection(u.hostname or "127.0.0.1", u.port or 80, timeout=timeout)
        path = u.path + (("?" + u.query) if u.query else "")
        conn.request("GET", path, headers={"Accept": "application/json"})
        resp = conn.getresponse()
        if resp.status != 200:
            return None
        body = resp.read()
        return json.loads(body.decode("utf-8"))
    except Exception:
        return None
    finally:
        try:
            conn.close()
        except Exception:
            pass

async def export_positions() -> List[Dict[str, Any]]:
    """
    Prefer the IBKR API cache (runtime/cache/positions.json) to avoid any
    hard dependency or blocking. If missing/stale, try a quick local HTTP hit.
    Always write exports/positions.json for inspection and return a list.
    """
    # 1) Read cached positions dumped by ibkr_api.py
    cached = _read_json_file(CACHE_DIR / "positions.json", default=None)
    rows: List[Dict[str, Any]] = []
    if isinstance(cached, list):
        rows = [dict(r) for r in cached]
    # 2) If no cache, attempt a quick localhost fetch (best-effort)
    if not rows:
        api_base = os.getenv("TB_API_BASE", "http://127.0.0.1:8000")
        fresh = _http_json_get(f"{api_base}/ibkr/positions", timeout=2.5)
        if isinstance(fresh, list):
            rows = [dict(r) for r in fresh]
    # Normalize fields, compute USD notionals and summaries
    total_positions = len(rows)
    by_ccy: Dict[str, int] = {}
    usd_by_ccy: Dict[str, float] = {}
    grand_usd = 0.0
    for r in rows:
        try:
            r["symbol"] = (r.get("symbol") or "").upper()
            r["secType"] = (r.get("secType") or "").upper()
            r["currency"] = (r.get("currency") or "USD").upper()
            r["exchange"] = (r.get("exchange") or r.get("primaryExchange") or "SMART")
            # sanitize numerics
            pos = r.get("position")
            r["position"] = float(pos) if pos is not None else 0.0
            avg = r.get("avgCost")
            r["avgCost"] = float(avg) if avg is not None else 0.0
            # simple notional in account currency (only reliable when currency == USD)
            usd = r["position"] * r["avgCost"] if r["currency"] == "USD" else 0.0
            r["usd"] = usd
            by_ccy[r["currency"]] = by_ccy.get(r["currency"], 0) + 1
            if r["currency"] == "USD":
                usd_by_ccy["USD"] = usd_by_ccy.get("USD", 0.0) + usd
                grand_usd += usd
        except Exception:
            continue
    # 3) Persist a pretty export for humans
    try:
        (EXPORTS / "positions.json").write_text(json.dumps({"positions": rows}, indent=2), encoding="utf-8")
    except Exception:
        pass
    # 3b) Rolling snapshot for time-based trends/sparklines
    try:
        ts = datetime.utcnow().strftime("%Y%m%dT%H%M%SZ")
        snap = {
            "ts": ts,
            "positions": [
                # keep just the essential fields in the history to stay light
                {
                    "symbol": r.get("symbol"),
                    "secType": r.get("secType"),
                    "currency": r.get("currency"),
                    "position": r.get("position"),
                    "avgCost": r.get("avgCost"),
                    "usd": r.get("usd", 0.0),
                } for r in rows
            ],
            "totals": {
                "count": total_positions,
                "byCurrency": by_ccy,
                "usdByCurrency": usd_by_ccy,
                "grandUSD": grand_usd,
            }
        }
        (HIST / f"positions-{ts}.json").write_text(json.dumps(snap, indent=2), encoding="utf-8")
    except Exception:
        pass

    # Attach a small meta dict for dashboards
    meta = {
        "count": total_positions,
        "byCurrency": by_ccy,
        "usdByCurrency": usd_by_ccy,
        "grandUSD": grand_usd,
    }
    # Also store a compact machine snapshot in runtime for other processes if useful
    try:
        _write_atomic(RUNTIME / "positions.state.json", json.dumps({"positions": rows, "meta": meta}, separators=(",", ":"), ensure_ascii=False))
    except Exception:
        pass
    # stash meta on function for reuse (no globals churn)
    export_positions.meta = meta  # type: ignore[attr-defined]
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
                positions = await export_positions()
                for p in await fetch_pending_plans(session):
                    await process_plan(session, p)
                await session.commit()
                # ---- Build UI snapshot for /api/bootstrap + /sse/updates ----
                symbols = [str(a.get("symbol","")).upper() for a in (assets or [])][:50]
                sparks = _compute_sparks_from_history(HIST, symbols, max_points=60)
                positions = _read_positions_cache()  # last-known (offline-safe)
                snap = {
                    "ts": int(time.time()),
                    "updated_iso": datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
                    "health": _read_health(),
                    "accounts": accounts or [],
                    "assets": assets or [],
                    "positions": positions or [],
                    "positionsMeta": getattr(export_positions, "meta", {"count": 0, "byCurrency": {}, "usdByCurrency": {}, "grandUSD": 0.0}),
                    "sparks": sparks,  # symbol -> [0..1] series (may be empty initially)
                    "positions": positions,  # <-- now included in bootstrap/SSE
                    "names": _read_pretty_names(),   # <-- add this line
                }
                # Write atomically so web readers never see partial JSON
                _write_atomic(STATE_FP, json.dumps(snap, separators=(",", ":"), ensure_ascii=False))

            except Exception as e:
                # You can log this to logs/engine.log
                pass
        await asyncio.sleep(interval)

if __name__ == "__main__":
    asyncio.run(engine_loop())
