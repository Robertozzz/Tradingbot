from __future__ import annotations
import asyncio
import json
import math
import os
import time
from datetime import datetime
from decimal import Decimal
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple

from fastapi import APIRouter, HTTPException
from fastapi.responses import StreamingResponse

router = APIRouter(prefix="/api", tags=["api"])

def _candidate_dirs()->List[Path]:
    here = Path(__file__).resolve()
    # engine may write to exports/ or runtime/
    return [
        here.parent.parent / "exports",
        here.parent / "exports",
        Path.cwd() / "exports",
        here.parent.parent / "runtime",
        here.parent / "runtime",
        Path.cwd() / "runtime",
    ]

def _find_dir()->Path:
    for p in _candidate_dirs():
        if p.exists():
            return p
    # make a default
    d = Path.cwd() / "exports"
    d.mkdir(parents=True, exist_ok=True)
    return d

EXPORTS = _find_dir()

def _load_json(p:Path)->Any:
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except FileNotFoundError:
        raise HTTPException(404, detail=f"Missing file: {p.name}")
    except json.JSONDecodeError as e:
        raise HTTPException(500, detail=f"Bad JSON in {p.name}: {e}")

def _latest(globpat:str)->Optional[Path]:
    files = sorted(EXPORTS.glob(globpat), key=lambda x: x.stat().st_mtime, reverse=True)
    return files[0] if files else None

def _dec(x:Any)->Decimal:
    try: return Decimal(str(x))
    except: return Decimal("0")

def _sym(a:Dict[str,Any])->str:
    return a.get("symbol") or a.get("asset") or a.get("coin") or "UNKNOWN"

def _usd(a:Dict[str,Any])->Decimal:
    for k in ("usd","total_usd","value_usd","total","value"):
        if k in a and a[k] is not None: return _dec(a[k])
    qty = _dec(a.get("quantity") or a.get("qty") or 0)
    price = _dec(a.get("price") or 0)
    return qty*price

def _hist_dir()->Path:
    for n in ("history","hist","_history"):
        p = EXPORTS / n
        if p.exists(): return p
    return EXPORTS / "history"

def _iter_hist_assets()->List[Path]:
    d = _hist_dir()
    pats = ["assets-*.json","assets_*.json","assets.*.json","assets.json"]
    out: List[Path] = []
    if d.exists():
        for pat in pats: out += list(d.glob(pat))
    if not out:
        for pat in pats: out += list(EXPORTS.glob(pat))
    out = [p for p in out if p.is_file()]
    out.sort(key=lambda p: p.stat().st_mtime)
    return out

def _extract_assets(snap:Any)->List[Dict[str,Any]]:
    if isinstance(snap, dict) and "assets" in snap and isinstance(snap["assets"], list):
        return snap["assets"]
    if isinstance(snap, list): return snap
    return []

def _build_series(window:int=48)->Dict[str,List[Tuple[float,float]]]:
    files = _iter_hist_assets()
    if not files: return {}
    files = files[-window:]
    series: Dict[str,List[Tuple[float,float]]] = {}
    for p in files:
        try: snap = _load_json(p)
        except HTTPException: continue
        ts = p.stat().st_mtime
        for a in _extract_assets(snap):
            sym = _sym(a); val = float(_usd(a))
            series.setdefault(sym, []).append((ts, val))
    return series

def _spark_norm(points:List[Tuple[float,float]])->List[float]:
    if not points: return []
    vals = [v for _,v in points]
    mn, mx = min(vals), max(vals)
    if mx-mn < 1e-12: return [0.5 for _ in vals]
    return [(v-mn)/(mx-mn) for v in vals]

def _synth(symbol:str, base:float, n:int=24)->List[Tuple[float,float]]:
    if base <= 0: base = 1.0
    seed = sum(ord(c) for c in symbol) or 1
    now = time.time()
    pts = []
    for i in range(n):
        delta = (math.sin((i+seed%7)/3.0)*0.02 + math.cos((i+seed%11)/4.0)*0.01)
        pts.append((now-(n-i)*3600, float(base*(1.0+delta))))
    return pts

@router.get("/assets")
def assets()->Any:
    p = _latest("assets*.json")
    if not p: raise HTTPException(404, detail="assets export not found")
    data = _load_json(p)
    items = data["assets"] if isinstance(data, dict) and "assets" in data else data if isinstance(data, list) else []
    series = _build_series(window=64)
    out = []
    for a in items:
        sym = _sym(a); now = float(_usd(a))
        pts = series.get(sym) or _synth(sym, now, n=24)
        out.append({**a, "_spark": _spark_norm(pts), "_spark_points": pts,
                    "_change_24h_pct": ((pts[-1][1]-pts[0][1])/pts[0][1]*100.0 if pts and pts[0][1] else 0.0)})
    return {"updated_at": datetime.utcnow().isoformat()+"Z", "count": len(out), "assets": out}

@router.get("/accounts")
def accounts()->Any:
    p = _latest("accounts*.json")
    if not p: raise HTTPException(404, detail="accounts export not found")
    data = _load_json(p)
    items = data["accounts"] if isinstance(data, dict) and "accounts" in data else data if isinstance(data, list) else []
    # use portfolio spark as placeholder
    series = _build_series(window=64)
    idx: Dict[float,float] = {}
    for sym, pts in series.items():
        for ts, v in pts: idx[ts] = idx.get(ts, 0.0) + v
    port_pts = sorted(idx.items())
    spark = _spark_norm(port_pts)
    out = [{**a, "_balance_spark": spark} for a in items]
    return {"updated_at": datetime.utcnow().isoformat()+"Z", "count": len(out), "accounts": out}

@router.get("/portfolio/summary")
def summary()->Any:
    p = _latest("assets*.json")
    if not p: raise HTTPException(404, detail="need assets.json for summary")
    data = _load_json(p)
    items = data["assets"] if isinstance(data, dict) and "assets" in data else data if isinstance(data, list) else []
    total = float(sum(_usd(a) for a in items))
    alloc = []
    for a in items:
        v = float(_usd(a)); sym = _sym(a)
        if v > 0: alloc.append({"symbol": sym, "value_usd": v})
    alloc.sort(key=lambda x: x["value_usd"], reverse=True)
    top = alloc[:8]
    # build portfolio spark
    series = _build_series(window=96)
    idx: Dict[float,float] = {}
    for sym, pts in series.items():
        for ts, v in pts: idx[ts] = idx.get(ts, 0.0) + v
    pts = sorted(idx.items())
    change = 0.0
    if len(pts)>=2 and pts[0][1]:
        change = (pts[-1][1]-pts[0][1])/pts[0][1]*100.0
    return {"total_usd": total, "top_allocation": top, "spark_points": pts, "change_window_pct": change}

# --- SSE ---
def _pack(event:str, data:Any)->bytes:
    return f"event: {event}\ndata: {json.dumps(data, separators=(',',':'))}\n\n".encode()

@router.get("/metrics/stream")
async def stream(poll: float = 1.0):
    assets_p = _latest("assets*.json")
    accounts_p = _latest("accounts*.json")
    watch = [p for p in [assets_p, accounts_p] if p]
    async def gen():
        last = {p.name: p.stat().st_mtime for p in watch}
        # initial burst
        yield _pack("summary", summary())
        while True:
            await asyncio.sleep(max(0.25, float(poll)))
            changed = False
            for p in list(watch):
                if not p.exists(): continue
                mt = p.stat().st_mtime
                if last.get(p.name) != mt:
                    last[p.name] = mt
                    changed = True
                    if "assets" in p.name: yield _pack("assets_changed", {"ts": time.time()})
                    if "accounts" in p.name: yield _pack("accounts_changed", {"ts": time.time()})
            if changed:
                yield _pack("summary", summary())
    return StreamingResponse(gen(), media_type="text/event-stream")
