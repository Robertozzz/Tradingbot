# web.py — serve Flutter Web + API, watchdog control, SSE, and log tails
from __future__ import annotations
import json, time, mimetypes, asyncio, io, os
from pathlib import Path
from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from fastapi.responses import FileResponse, JSONResponse, StreamingResponse
from fastapi import Body
from pydantic import BaseModel
from typing import Optional, List

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
    # If you build Flutter with the HTML renderer, do NOT set COOP/COEP at all.
    # These headers block third-party iframes like TradingView.
    # If you *must* keep them for some routes, guard them and leave the main UI un-isolated.
    # Example (commented out intentionally):
    # if request.url.path.startswith("/_iso"):  # hypothetical isolated area
    #     resp.headers["Cross-Origin-Opener-Policy"] = "same-origin"
    #     resp.headers["Cross-Origin-Embedder-Policy"] = "require-corp"
    #     resp.headers["Cross-Origin-Resource-Policy"] = "same-origin"
    if request.url.path in ("/", "/index.html"):
        resp.headers["Cache-Control"] = "no-store"
    if request.url.path.startswith("/flutter_service_worker.js"):
        resp.headers["Service-Worker-Allowed"] = "/"
        resp.headers.setdefault("Content-Type", "text/javascript")
    return resp

import logging
logging.basicConfig(level=logging.INFO)          # <— add this once
mount_log = logging.getLogger("mount")           # <— rename

try:
    from .api import router as api_router
    app.include_router(api_router, prefix="")    # router already has prefix="/api"
    mount_log.info("Mounted /api router")
except Exception as e:
    mount_log.exception("Failed to mount /api router")

try:
    from .ibkr_api import router as ibkr_router
    app.include_router(ibkr_router)              # exposes /ibkr/*
    mount_log.info("Mounted /ibkr router")
except Exception as e:
    mount_log.exception("Failed to mount /ibkr router")
    from fastapi import APIRouter
    mock = APIRouter(prefix="/ibkr", tags=["ibkr-mock"])

    @mock.get("/ping")
    async def _mock_ping():
        return {"connected": False, "server_time": None, "mock": True}

    @mock.get("/accounts")
    async def _mock_accounts():
        return {"DU1234567": {"NetLiquidation": "100000", "TotalCashValue": "20000"}}

    @mock.get("/positions")
    async def _mock_positions():
        return [
            {"account":"DU1234567","symbol":"AAPL","secType":"STK","currency":"USD","exchange":"SMART","position":50,"avgCost":172.12},
            {"account":"DU1234567","symbol":"MSFT","secType":"STK","currency":"USD","exchange":"SMART","position":20,"avgCost":318.40},
        ]
    app.include_router(mock)

# separate logger for auth mount
auth_log = logging.getLogger("auth")
try:
    from .auth import router as auth_router
    app.include_router(auth_router, prefix="")
    auth_log.info("Mounted /auth router")
except Exception as e:
    auth_log.exception("Failed to mount auth router")

# -------- OPENAI SETTINGS STORAGE --------
def _openai_settings_path() -> Path:
    rt = _runtime_dir()
    rt.mkdir(parents=True, exist_ok=True)
    return rt / "openai_settings.json"

def _load_openai_settings() -> dict:
    fp = _openai_settings_path()
    if fp.exists():
        try:
            return json.loads(fp.read_text(encoding="utf-8"))
        except Exception:
            pass
    # Defaults (safe fallbacks)
    return {
        "model": "gpt-5",
        "openai_api_key": "",       # stored locally; not returned to UI
        "search_api_key": "",
        "enable_browsing": True,
    }

def _save_openai_settings(data: dict) -> None:
    # Persist
    _openai_settings_path().write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
    # Also expose to process env so children reuse without restart
    if "openai_api_key" in data:
        os.environ["OPENAI_API_KEY"] = (data.get("openai_api_key") or "").strip()
    if "search_api_key" in data:
        os.environ["SEARCH_API_KEY"] = (data.get("search_api_key") or "").strip()
    if "model" in data:
        os.environ["OPENAI_MODEL"] = (data.get("model") or "gpt-5").strip()
    if "enable_browsing" in data:
        os.environ["OPENAI_ENABLE_BROWSING"] = "1" if data.get("enable_browsing") else "0"

class OpenAISettingsIn(BaseModel):
    model: str = "gpt-5"
    openai_api_key: str | None = None
    search_api_key: str | None = None
    enable_browsing: bool = True

@app.get("/api/openai/settings")
def get_openai_settings():
    """Return settings (without leaking the raw API key)."""
    data = _load_openai_settings()
    # never return raw key; just whether it's set
    return {
        "model": data.get("model", "gpt-5"),
        "has_openai_api_key": bool(data.get("openai_api_key")),
        "has_search_api_key": bool(data.get("search_api_key")),
        "enable_browsing": bool(data.get("enable_browsing", True)),
    }

@app.post("/api/openai/settings")
def update_openai_settings(payload: OpenAISettingsIn):
    current = _load_openai_settings()
    if payload.model:
        current["model"] = payload.model.strip()
    if payload.openai_api_key is not None:
        current["openai_api_key"] = payload.openai_api_key.strip() if payload.openai_api_key else ""
    if payload.search_api_key is not None:
        current["search_api_key"] = payload.search_api_key.strip() if payload.search_api_key else ""
    current["enable_browsing"] = bool(payload.enable_browsing)
    _save_openai_settings(current)
    return {"ok": True}

@app.post("/api/openai/test")
def openai_test(body: dict = Body(default={})):
    """
    Light 'ping'—asks the model to reply 'pong'.
    Useful to validate key/model from the UI without heavy cost.
    """
    try:
        from . import openai as ai
        # ensure runtime settings are applied
        ai.apply_runtime_settings()
        if not os.environ.get("OPENAI_API_KEY"):
            raise HTTPException(400, "OpenAI API key not set. Save it in Settings first.")
        txt, usage = ai.test_openai(prompt=body.get("prompt") or "ping")
        return {"ok": True, "reply": txt, "usage": usage}
    except Exception as e:
        raise HTTPException(500, f"OpenAI test failed: {e}")
    
# --- Optional: quick Bing search test without invoking GPT ---
class SearchTestIn(BaseModel):
    query: str
    mode: str = "news"            # "news" or "web"
    count: int = 5
    mkt: str = "en-US"
    freshness: Optional[str] = None
    sites: Optional[List[str]] = None

@app.post("/api/openai/search_test")
def search_test(payload: SearchTestIn):
    try:
        from . import openai as ai
        ai.apply_runtime_settings()
        out = ai.tool_web_search(
            payload.query,
            count=payload.count,
            mode=payload.mode,
            mkt=payload.mkt,
            freshness=payload.freshness,
            sites=payload.sites,
        )
        return {"ok": True, "results": out}
    except Exception as e:
        raise HTTPException(500, f"Bing search failed: {e}")
    
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
    
def _enqueue_control(module: str, action: str) -> dict:
    """Enqueue a control command for the watchdog and return a status dict."""
    module = module.strip().lower()
    action = action.strip().lower()
    rt = _runtime_dir()
    cmd_dir = rt / "cmd"
    cmd_dir.mkdir(parents=True, exist_ok=True)
    ts = int(time.time())
    payload = {"target": module, "action": action, "ts": ts}
    (cmd_dir / f"{ts}_{module}_{action}.json").write_text(json.dumps(payload), encoding="utf-8")
    # instant feedback for the watchdog/UI
    (rt / "watchdog.signal").write_text(str(ts), encoding="utf-8")
    queued = dict(payload); queued["state"] = "queued"
    (rt / "last_cmd.json").write_text(json.dumps(queued), encoding="utf-8")
    return {"ok": True, "module": module, "action": action, "ts": ts, "queue_len": _queue_len()}

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
async def system_control_endpoint(request: Request):
    body = await request.json()
    module = (body.get("module") or "").strip().lower()
    action = (body.get("action") or "").strip().lower()
    if module not in {"engine","web","telegram","api","base","ibgateway"}:
        raise HTTPException(400, "Unknown module")
    if action not in {"start","stop","restart","drain"}:
        raise HTTPException(400, "Unknown action")
    return _enqueue_control(module, action)

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
