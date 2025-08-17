# base.py — watchdog with richer feedback
from __future__ import annotations
import os, sys, time, signal, subprocess, http.client, urllib.parse, json
from dataclasses import dataclass, field
from typing import List, Optional, Deque, Callable
from pathlib import Path
from collections import deque

# -------------------- env --------------------
def load_dotenv(path: str = ".env"):
    try:
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                k = k.strip(); v = v.strip().strip('"').strip("'")
                if k and k not in os.environ:
                    os.environ[k] = v
    except FileNotFoundError:
        pass

load_dotenv()

PYTHON = sys.executable
HOST = "127.0.0.1"
WEB_PORT = 8000

ENGINE_HEARTBEAT = Path("engine.heartbeat")
WEB_HEARTBEAT = Path("web.heartbeat")

TELEGRAM_ENABLED = True
CHECK_INTERVAL = 3
UNHEALTHY_GRACE = 15
RESTART_BACKOFF_MAX = 60

LOG_DIR = Path("logs"); LOG_DIR.mkdir(exist_ok=True)
RUNTIME_DIR = Path("runtime"); RUNTIME_DIR.mkdir(exist_ok=True)
CMD_DIR = RUNTIME_DIR / "cmd"; CMD_DIR.mkdir(exist_ok=True)
STATUS_FILE = RUNTIME_DIR / "status.json"
LAST_CMD_FILE = RUNTIME_DIR / "last_cmd.json"

ALERT_WINDOW_SEC = 120
ALERT_MAX_RESTARTS = 3
ALERT_COOLDOWN_SEC = 300

TG_TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN", "").strip()
TG_CHAT  = os.environ.get("TELEGRAM_CHAT_ID", "").strip()

# -------------------- types --------------------
@dataclass
class ProcSpec:
    name: str
    cmd: List[str]
    health_check: Callable[[], bool]
    proc: Optional[subprocess.Popen] = None
    last_start: float = 0.0
    backoff: int = 0
    unhealthy_since: Optional[float] = None
    restart_times: Deque[float] = field(default_factory=lambda: deque(maxlen=50))
    last_alert: float = 0.0
    last_exit_code: Optional[int] = None
    last_exit_ts: Optional[float] = None

# -------------------- helpers --------------------
def _log_path(name: str) -> Path:
    return LOG_DIR / f"{name}.log"

def _set_last_cmd_state(payload: dict, state: str, extra: dict | None = None):
    try:
        rec = dict(payload)
        rec["state"] = state  # queued | applied | executing | done | error
        rec["applied_ts" if state != "queued" else "queued_ts"] = int(time.time())
        if extra: rec.update(extra)
        LAST_CMD_FILE.write_text(json.dumps(rec), encoding="utf-8")
    except Exception:
        pass

def _start(spec: ProcSpec):
    now = time.time()
    wait = min(spec.backoff, RESTART_BACKOFF_MAX)
    if wait > 0 and (now - spec.last_start) < wait:
        time.sleep(wait - (now - spec.last_start))
    logf = open(_log_path(spec.name), "ab", buffering=0)
    spec.proc = subprocess.Popen(
        spec.cmd,
        stdout=logf, stderr=subprocess.STDOUT,
        bufsize=1, close_fds=os.name != "nt"
    )
    spec.last_start = time.time()
    spec.last_exit_code = None
    spec.last_exit_ts = None
    spec.restart_times.append(spec.last_start)
    spec.backoff = min(spec.backoff * 2 + 1, RESTART_BACKOFF_MAX) if spec.backoff else 1

def _stop(spec: ProcSpec, timeout=10):
    if spec.proc and spec.proc.poll() is None:
        try:
            spec.proc.terminate()
            t0 = time.time()
            while time.time() - t0 < timeout:
                if spec.proc.poll() is not None:
                    break
                time.sleep(0.2)
            if spec.proc.poll() is None:
                spec.proc.kill()
        except Exception:
            pass
    if spec.proc:
        spec.last_exit_code = spec.proc.poll()
        spec.last_exit_ts = time.time()
    spec.proc = None

def _is_running(spec: ProcSpec) -> bool:
    return spec.proc is not None and spec.proc.poll() is None

def _send_telegram(text: str):
    if not (TG_TOKEN and TG_CHAT):
        return
    try:
        conn = http.client.HTTPSConnection("api.telegram.org", timeout=5)
        path = f"/bot{TG_TOKEN}/sendMessage"
        payload = urllib.parse.urlencode({"chat_id": TG_CHAT, "text": text})
        headers = {"Content-Type": "application/x-www-form-urlencoded"}
        conn.request("POST", path, payload, headers)
        resp = conn.getresponse(); resp.read(); conn.close()
    except Exception:
        pass

def _maybe_alert(spec: ProcSpec, reason: str):
    now = time.time()
    recent = [t for t in spec.restart_times if now - t <= ALERT_WINDOW_SEC]
    if len(recent) > ALERT_MAX_RESTARTS and (now - spec.last_alert) > ALERT_COOLDOWN_SEC:
        spec.last_alert = now
        _send_telegram(f"[WATCHDOG] {spec.name} restarted {len(recent)}x in {ALERT_WINDOW_SEC}s. Reason: {reason}")

def web_healthy() -> bool:
    try:
        conn = http.client.HTTPConnection(HOST, WEB_PORT, timeout=2)
        conn.request("GET", "/health")
        r = conn.getresponse(); ok = (200 <= r.status < 300); conn.close()
        if ok:
            return True
    except Exception:
        pass
    try:
        if not WEB_HEARTBEAT.exists():
            return False
        age = time.time() - WEB_HEARTBEAT.stat().st_mtime
        return age < UNHEALTHY_GRACE
    except Exception:
        return False

def engine_healthy() -> bool:
    try:
        if not ENGINE_HEARTBEAT.exists():
            return False
        age = time.time() - ENGINE_HEARTBEAT.stat().st_mtime
        return age < UNHEALTHY_GRACE
    except Exception:
        return False

def telegram_healthy() -> bool:
    return True

def build_specs() -> list[ProcSpec]:
    specs = [
        ProcSpec(
            name="web",
            cmd=[PYTHON, "-m", "uvicorn", "app.web:app", "--host", HOST, "--port", str(WEB_PORT)],
            health_check=web_healthy
        ),
        ProcSpec(
            name="engine",
            cmd=[PYTHON, "-m", "app.engine"],
            health_check=engine_healthy
        ),
    ]
    if TELEGRAM_ENABLED:
        specs.append(ProcSpec(
            name="telegram",
            cmd=[PYTHON, "-m", "app.telegram_bot"],
            health_check=telegram_healthy
        ))
    return specs

def _queue_len() -> int:
    try:
        return sum(1 for _ in CMD_DIR.glob("*.json"))
    except Exception:
        return 0

def _state_reason(s: ProcSpec, alive: bool, healthy: bool) -> str:
    if not alive:
        if s.last_exit_code is not None:
            return f"stopped (exit {s.last_exit_code})"
        return "not running"
    if not healthy:
        if s.unhealthy_since:
            return f"unhealthy for {int(time.time()-s.unhealthy_since)}s"
        return "health check failed"
    return "ok"

def _snapshot_status(specs: list[ProcSpec]):
    data = {}
    for s in specs:
        alive = _is_running(s)
        healthy = s.health_check() if alive else False
        data[s.name] = {
            "running": alive,
            "healthy": healthy,
            "pid": (s.proc.pid if alive else None) if s.proc else None,
            "backoff": s.backoff,
            "last_start": s.last_start,
            "last_exit_code": s.last_exit_code,
            "last_exit_ts": s.last_exit_ts,
            "reason": _state_reason(s, alive, healthy),
        }
    meta = {
        "ts": int(time.time()),
        "queue_len": _queue_len(),
    }
    try:
        if LAST_CMD_FILE.exists():
            meta["last_cmd"] = json.loads(LAST_CMD_FILE.read_text(encoding="utf-8"))
    except Exception:
        pass
    data["_meta"] = meta
    try:
        STATUS_FILE.write_text(json.dumps(data), encoding="utf-8")
    except Exception:
        pass

def _read_cmds():
    cmds = []
    try:
        for fp in sorted(CMD_DIR.glob("*.json"), key=lambda p: p.name):
            try:
                obj = json.loads(fp.read_text(encoding="utf-8"))
            except Exception:
                obj = {"file": fp.name}
            cmds.append((fp, obj))
    except Exception:
        pass
    return cmds

def _apply_cmd(specs: list[ProcSpec], cmd: dict):
    target = cmd.get("target")
    action = cmd.get("action")
    name_to_spec = {s.name: s for s in specs}
    s = name_to_spec.get(target)
    if not s:
        _set_last_cmd_state(cmd, "error", {"error": "unknown target"})
        return

    _set_last_cmd_state(cmd, "applied")

    try:
        if action == "restart":
            _set_last_cmd_state(cmd, "executing", {"note": "restart"})
            _stop(s); _start(s)
        elif action == "stop":
            if s.name == "web":
                _set_last_cmd_state(cmd, "error", {"error": "refuse to stop web"})
                return
            _set_last_cmd_state(cmd, "executing", {"note": "stop"})
            _stop(s)
        elif action == "start":
            if _is_running(s):
                _set_last_cmd_state(cmd, "done", {"note": "already running", "pid": s.proc.pid})
                return
            _set_last_cmd_state(cmd, "executing", {"note": "start"})
            _start(s)
        elif action == "drain" and s.name == "engine":
            _set_last_cmd_state(cmd, "executing", {"note": "drain"})
            (RUNTIME_DIR / "engine.drain").write_text("1", encoding="utf-8")
        else:
            _set_last_cmd_state(cmd, "error", {"error": "unknown action"})
            return
        _set_last_cmd_state(cmd, "done", {"pid": s.proc.pid if s.proc else None})
    except Exception as e:
        _set_last_cmd_state(cmd, "error", {"error": str(e)})

running = True
def handle_signal(signum, frame):
    global running
    running = False

signal.signal(signal.SIGINT, handle_signal)
signal.signal(signal.SIGTERM, handle_signal)

def _maybe_reset_backoff(s: ProcSpec):
    if s.backoff and (time.time() - s.last_start) > 30:
        s.backoff = 0

def main():
    specs = build_specs()
    for s in specs:
        _start(s)

    while running:
        time.sleep(CHECK_INTERVAL)

        for fp, obj in _read_cmds():
            try:
                _apply_cmd(specs, obj)
            finally:
                try: fp.unlink()
                except Exception: pass

        _snapshot_status(specs)

        for s in specs:
            alive = _is_running(s)
            healthy = s.health_check() if alive else False

            if not alive:
                _maybe_alert(s, "process exited")
                _start(s)
                continue

            if healthy:
                s.unhealthy_since = None
                _maybe_reset_backoff(s)
                continue

            if s.unhealthy_since is None:
                s.unhealthy_since = time.time()
            elif (time.time() - s.unhealthy_since) >= UNHEALTHY_GRACE:
                _maybe_alert(s, "unhealthy")
                _stop(s); _start(s)

    for s in specs:
        _stop(s)

if __name__ == "__main__":
    main()
