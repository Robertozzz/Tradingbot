# web.py — serve Flutter Web + API, watchdog control, SSE, and log tails
from __future__ import annotations
import json, time, mimetypes, asyncio, io, os
from pathlib import Path
from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from fastapi.responses import FileResponse, JSONResponse, StreamingResponse

mimetypes.init()
mimetypes.add_type("text/javascript", ".mjs")
mimetypes.add_type("text/javascript", ".js")
mimetypes.add_type("application/wasm", ".wasm")
mimetypes.add_type("application/manifest+json", ".webmanifest")

app = FastAPI(title="TradingBot", version="flutter-host")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)

@app.middleware("http")
async def coi_headers(request: Request, call_next):
    resp = await call_next(request)
    resp.headers["Cross-Origin-Opener-Policy"] = "same-origin"
    resp.headers["Cross-Origin-Embedder-Policy"] = "require-corp"
    resp.headers["Cross-Origin-Resource-Policy"] = "same-origin"
    if request.url.path in ("/", "/index.html"):
        resp.headers["Cache-Control"] = "no-store"
    if request.url.path.startswith("/flutter_service_worker.js"):
        resp.headers["Service-Worker-Allowed"] = "/"
        resp.headers.setdefault("Content-Type", "text/javascript")
    return resp

# Optional: include your other routers first
try:
    from .api import router as api_router
    app.include_router(api_router, prefix="")
except Exception:
    pass
    
import logging
log = logging.getLogger("auth")
    
try:
    from .auth import router as auth_router
    app.include_router(auth_router, prefix="")
except Exception as e:
    log.exception("Failed to mount auth router")

def _runtime_dir() -> Path:
    for p in [
        Path(__file__).resolve().parent.parent / "runtime",
        Path(__file__).resolve().parent / "runtime",
        Path.cwd() / "runtime",
    ]:
        if p.exists():
            return p
    d = Path.cwd() / "runtime"
    d.mkdir(parents=True, exist_ok=True)
    return d

def _logs_dir() -> Path:
    for p in [Path(__file__).resolve().parent.parent / "logs", Path("logs")]:
        if p.exists():
            return p
    d = Path("logs"); d.mkdir(exist_ok=True)
    return d

def _queue_len() -> int:
    try:
        return sum(1 for _ in (_runtime_dir() / "cmd").glob("*.json"))
    except Exception:
        return 0

@app.get("/health")
def health():
    return {"ok": True, "ts": time.time()}

@app.get("/system/status")
def system_status():
    rt = _runtime_dir()
    fp = rt / "status.json"
    data = {}
    if fp.exists():
        try:
            data = json.loads(fp.read_text(encoding="utf-8"))
        except json.JSONDecodeError as e:
            raise HTTPException(500, f"Malformed runtime/status.json: {e}")

    data.setdefault("_meta", {})
    data["_meta"]["ts"] = int(time.time())
    data["_meta"]["queue_len"] = _queue_len()
    last_cmd = rt / "last_cmd.json"
    if last_cmd.exists():
        try:
            data["_meta"]["last_cmd"] = json.loads(last_cmd.read_text(encoding="utf-8"))
        except Exception:
            pass
    return data

@app.post("/system/control")
async def system_control(request: Request):
    body = await request.json()
    module = (body.get("module") or "").strip().lower()
    action = (body.get("action") or "").strip().lower()
    if module not in {"engine","web","telegram","api","base","ibgateway"}:
        raise HTTPException(400, "Unknown module")
    if action not in {"start","stop","restart","drain"}:
        raise HTTPException(400, "Unknown action")

    rt = _runtime_dir()
    cmd_dir = rt / "cmd"
    cmd_dir.mkdir(parents=True, exist_ok=True)

    ts = int(time.time())
    payload = {"target": module, "action": action, "ts": ts}
    (cmd_dir / f"{ts}_{module}_{action}.json").write_text(json.dumps(payload), encoding="utf-8")

    # instant feedback
    (rt / "watchdog.signal").write_text(str(ts), encoding="utf-8")
    queued = dict(payload); queued["state"] = "queued"
    (rt / "last_cmd.json").write_text(json.dumps(queued), encoding="utf-8")

    return {"ok": True, "module": module, "action": action, "ts": ts, "queue_len": _queue_len()}

# ---- log tail endpoint (used by Watchdog UI) ----
@app.get("/system/logs/{name}")
def logs_tail(name: str, bytes: int = 4000):
    log_fp = _logs_dir() / f"{name}.log"
    if not log_fp.exists():
        return {"name": name, "exists": False, "tail": "", "size": 0, "truncated": False}
    size = log_fp.stat().st_size
    start = max(0, size - max(512, bytes))
    with open(log_fp, "rb") as f:
        f.seek(start)
        buf = f.read()
    try:
        text = buf.decode("utf-8", errors="replace")
    except Exception:
        text = ""
    return {"name": name, "exists": True, "tail": text, "size": size, "truncated": start > 0}

# ---- SSE: push status.json changes (optional; polling also works) ----
@app.get("/system/stream")
async def system_stream():
    async def event_gen():
        rt = _runtime_dir()
        status = rt / "status.json"
        last_mtime = 0.0
        while True:
            try:
                m = status.stat().st_mtime
                if m != last_mtime:
                    last_mtime = m
                    payload = status.read_text(encoding="utf-8")
                    yield f"event: status\ndata: {payload}\n\n"
            except FileNotFoundError:
                yield "event: status\ndata: {}\n\n"
            await asyncio.sleep(1.0)
    return StreamingResponse(event_gen(), media_type="text/event-stream")

# (optional) mount /exports for quick inspection
for _p in [
    Path(__file__).resolve().parent.parent / "exports",
    Path(__file__).resolve().parent / "exports",
    Path.cwd() / "exports",
    Path(__file__).resolve().parent.parent / "runtime",
    Path(__file__).resolve().parent / "runtime",
    Path.cwd() / "runtime",
]:
    if _p.exists():
        app.mount("/exports", StaticFiles(directory=str(_p), html=False), name="exports")
        break

# Serve Flutter build at /
UI_CANDIDATES = [
    Path(__file__).resolve().parent.parent / "ui_build",
    Path(__file__).resolve().parent / "ui_build",
    Path.cwd() / "ui_build",
    Path(__file__).resolve().parent.parent / "frontend" / "build" / "web",
]
FLUTTER_BUILD = next((p for p in UI_CANDIDATES if p.exists()), None)

if FLUTTER_BUILD and FLUTTER_BUILD.exists():
    app.mount("/", StaticFiles(directory=str(FLUTTER_BUILD), html=True), name="ui")

    @app.get("/{full_path:path}")
    def spa_fallback(full_path: str):
        if full_path.startswith(("api/", "system/", "exports/")):
            raise HTTPException(status_code=404)
        index = FLUTTER_BUILD / "index.html"
        if not index.exists():
            return JSONResponse({"error": "index.html not found"}, status_code=404)
        return FileResponse(index)
else:
    @app.get("/")
    def root_placeholder():
        return JSONResponse({
            "message": "Flutter build not found. Build with "
                       "`flutter build web --release --wasm --base-href /` "
                       "and copy build/web/* into ui_build/."
        })
