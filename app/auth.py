
from __future__ import annotations
import os, json, time, hmac, hashlib, base64
from pathlib import Path
from typing import Optional
from fastapi import APIRouter, HTTPException, Request, Response, Depends
from fastapi.responses import JSONResponse, StreamingResponse
from pydantic import BaseModel
from passlib.context import CryptContext
import pyotp
import re


router = APIRouter(prefix="/auth", tags=["auth"])

DATA_DIR = Path(os.environ.get("TB_RUNTIME_DIR") or Path.cwd() / "runtime")
DATA_DIR.mkdir(parents=True, exist_ok=True)
AUTH_FILE = DATA_DIR / "auth.json"

pwd_ctx = CryptContext(schemes=["bcrypt"], deprecated="auto")
COOKIE_NAME = "tb_session"
COOKIE_TTL = 60 * 60 * 8  # 8h
NAME_RX = re.compile(r"^[A-Za-z0-9_.-]{3,32}$")

def _now() -> int: return int(time.time())

def _sign(value: str, key: str) -> str:
    mac = hmac.new(key.encode(), value.encode(), hashlib.sha256).digest()
    return base64.urlsafe_b64encode(mac).decode().rstrip("=")

def _make_cookie(user: str, key: str) -> str:
    exp = _now() + COOKIE_TTL
    payload = f"{user}.{exp}"
    sig = _sign(payload, key)
    return f"{payload}.{sig}"

def _verify_cookie(cookie: str, key: str) -> Optional[str]:
    try:
        user, exp, sig = cookie.split(".", 2)
        payload = f"{user}.{exp}"
        if hmac.compare_digest(sig, _sign(payload, key)) and _now() < int(exp):
            return user
    except Exception:
        pass
    return None

def _load_auth():
    if AUTH_FILE.exists():
        try:
            return json.loads(AUTH_FILE.read_text("utf-8"))
        except Exception:
            pass
    # default: first run, no password yet
    return {"user": "admin", "password_hash": None, "totp_secret": None, "enrolled": False, "created_ts": _now(), "session_key": base64.urlsafe_b64encode(os.urandom(24)).decode()}

def _save_auth(data: dict):
    AUTH_FILE.write_text(json.dumps(data), encoding="utf-8")

class LoginReq(BaseModel):
    username: str
    password: str
    code: Optional[str] = None

@router.post("/init")
def init_account(body: InitReq):
    data = _load_auth()
    if data.get("password_hash"):
        raise HTTPException(400, "Already initialized")
    if len(body.new_password) < 8:
        raise HTTPException(400, "Password too short")
    data["password_hash"] = pwd_ctx.hash(body.new_password)
    # Generate TOTP secret now; enrollment will show the QR
    data["totp_secret"] = pyotp.random_base32()
    data["enrolled"] = False
    _save_auth(data)
    return {"ok": True, "stage": "enroll"}

class EnrollReq(BaseModel):
    code: str

@router.get("/enroll_qr")
def enroll_qr():
    data = _load_auth()
    if not data.get("password_hash"):
        raise HTTPException(400, "Not initialized")
    secret = data.get("totp_secret") or pyotp.random_base32()
    data["totp_secret"] = secret
    _save_auth(data)
    # Build provisioning URI
    issuer = "TradingBot"
    account = data.get("user","admin")
    uri = pyotp.totp.TOTP(secret).provisioning_uri(name=account, issuer_name=issuer)
    # Generate PNG QR (lazy dependency: qrcode)
    import qrcode
    import io
    buf = io.BytesIO()
    img = qrcode.make(uri)
    img.save(buf, format="PNG")
    buf.seek(0)
    return StreamingResponse(buf, media_type="image/png")

@router.post("/enroll")
def enroll(body: EnrollReq):
    data = _load_auth()
    if not data.get("password_hash"):
        raise HTTPException(400, "Not initialized")
    totp = pyotp.TOTP(data["totp_secret"])
    if not totp.verify(body.code, valid_window=1):
        raise HTTPException(401, "Invalid TOTP")
    data["enrolled"] = True
    _save_auth(data)
    return {"ok": True}

@router.post("/login")
def login(body: LoginReq, response: Response):
    data = _load_auth()
    if not data.get("password_hash"):
        # not initialized: ask to set password
        return JSONResponse({"ok": False, "stage": "init"}, status_code=403)
    if body.username != data.get("user"):
        raise HTTPException(401, "Invalid credentials")
    if not pwd_ctx.verify(body.password, data["password_hash"]):
        raise HTTPException(401, "Invalid credentials")
    if not data.get("enrolled"):
        # Require enrollment step
        return JSONResponse({"ok": False, "stage": "enroll"}, status_code=403)
    # Verify TOTP
    totp = pyotp.TOTP(data["totp_secret"])
    if not (body.code and totp.verify(body.code, valid_window=1)):
        raise HTTPException(401, "Invalid TOTP")
    session = _make_cookie(data["user"], data["session_key"])
    response.set_cookie(
        COOKIE_NAME, session, max_age=COOKIE_TTL, httponly=True, secure=(os.environ.get("TB_INSECURE_COOKIES")!="1"), samesite="Strict", path="/"
    )
    return {"ok": True}

@router.post("/logout")
def logout(response: Response):
    response.delete_cookie(COOKIE_NAME, path="/")
    return {"ok": True}

def require_session(request: Request):
    data = _load_auth()
    session = request.cookies.get(COOKIE_NAME)
    if not session:
        raise HTTPException(401, "No session")
    user = _verify_cookie(session, data["session_key"])
    if not user:
        raise HTTPException(401, "Invalid session")
    return user

@router.get("/validate")
def validate(_: str = Depends(require_session)):
    return {"ok": True}

@router.get("/state")
def state():
    data = _load_auth()
    if not data.get("password_hash"):
        return {"stage": "init"}      # first run → set password
    if not data.get("enrolled"):
        return {"stage": "enroll"}    # show QR + verify first TOTP
    return {"stage": "login"}         # normal login thereafter

class InitReq(BaseModel):
    username: str | None = None
    new_password: str

@router.post("/init")
def init_account(body: InitReq):
    data = _load_auth()
    if data.get("password_hash"):
        raise HTTPException(400, "Already initialized")
    if len(body.new_password or "") < 8:
        raise HTTPException(400, "Password too short")

    user = (body.username or "admin").strip()
    if not NAME_RX.match(user):
        raise HTTPException(400, "Invalid username (3–32 chars: letters, digits, _.-)")

    data["user"] = user
    data["password_hash"] = pwd_ctx.hash(body.new_password)
    data["totp_secret"] = pyotp.random_base32()
    data["enrolled"] = False
    _save_auth(data)
    return {"ok": True, "stage": "enroll"}