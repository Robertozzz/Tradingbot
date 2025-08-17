#!/usr/bin/env bash
# install_tradingbot.sh
# One-shot installer for Debian 12/13 (no GUI).
# Sets up: FastAPI (uvicorn), auth (password + TOTP), Nginx (+TLS optional),
# noVNC + websockify, and IBKR Gateway (Xvfb + openbox + x11vnc).
#
# Usage (pick ONE source method):
#   sudo bash install_tradingbot.sh --domain bot.example.com --email you@example.com \
#     --git https://github.com/you/your-tradingbot.git --branch main
#   # OR
#   sudo bash install_tradingbot.sh --domain bot.example.com --email you@example.com \
#     --zip https://example.com/tradingbot_bundle.zip
#   # Dev mode (HTTP only, no TLS):
#   sudo bash install_tradingbot.sh --no-tls --domain myvm.local --email you@example.com \
#     --git https://github.com/you/your-tradingbot.git --branch main

set -euo pipefail

# ---- Args ----
DOMAIN=""
EMAIL=""
ZIP_SRC=""
GIT_URL=""
GIT_BRANCH="main"
NO_TLS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN="$2"; shift 2 ;;
    --email) EMAIL="$2"; shift 2 ;;
    --zip) ZIP_SRC="$2"; shift 2 ;;
    --git) GIT_URL="$2"; shift 2 ;;
    --branch) GIT_BRANCH="$2"; shift 2 ;;
    --no-tls) NO_TLS=1; shift 1 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$DOMAIN" || -z "$EMAIL" ]]; then
  echo "ERROR: --domain and --email are required." >&2
  exit 2
fi

if [[ -z "$ZIP_SRC" && -z "$GIT_URL" ]]; then
  echo "NOTE: No --zip or --git specified. The installer will create /opt/tradingbot; you can rsync your code later."
fi

# ---- Basics ----
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y \
  python3 python3-venv python3-pip python3-uvicorn python3-fastapi \
  python3-passlib python3-pyotp python3-qrcode \
  unzip curl ca-certificates git rsync \
  xvfb openbox x11vnc novnc websockify \
  nginx certbot python3-certbot-nginx \
  libgtk-3-0 libglib2.0-0 libpango-1.0-0 libcairo2 libgdk-pixbuf-2.0-0 \
  libxcomposite1 libxdamage1 libxfixes3 libxss1 libxtst6 libxi6 libxrandr2 \
  libnss3 libasound2 libatk1.0-0 libatk-bridge2.0-0 libcups2 \
  libx11-xcb1 libxcb1 libxcb-render0 libxcb-shm0 libdrm2 libgbm1 \
  libfontconfig1 fonts-dejavu-core

# ---- Users / dirs ----
id -u ibkr >/dev/null 2>&1 || useradd -m -s /bin/bash ibkr
install -d -o root -g root -m 0755 /opt
install -d -o www-data -g www-data -m 0755 /opt/tradingbot
install -d -o www-data -g www-data -m 0755 /opt/tradingbot/runtime
install -d -o www-data -g www-data -m 0755 /opt/tradingbot/logs

# ---- Fetch code ----
TMPD="$(mktemp -d)"
if [[ -n "$ZIP_SRC" ]]; then
  if [[ "$ZIP_SRC" =~ ^https?:// ]]; then
    echo "[DL] Downloading bundle: $ZIP_SRC"
    curl -fL "$ZIP_SRC" -o "$TMPD/bundle.zip"
  else
    echo "[CP] Using local ZIP: $ZIP_SRC"
    cp "$ZIP_SRC" "$TMPD/bundle.zip"
  fi
  unzip -q "$TMPD/bundle.zip" -d "$TMPD/extract"
  SRC_ROOT="$(find "$TMPD/extract" -maxdepth 2 -type d -name app -printf '%h\n' | head -n1 || true)"
  [[ -z "$SRC_ROOT" ]] && SRC_ROOT="$TMPD/extract"
  rsync -a --delete "$SRC_ROOT"/ /opt/tradingbot/
elif [[ -n "$GIT_URL" ]]; then
  git clone --depth 1 --branch "$GIT_BRANCH" "$GIT_URL" "$TMPD/repo"
  rsync -a --delete "$TMPD/repo"/ /opt/tradingbot/
else
  echo "[SKIP] Using empty skeleton; ensure /opt/tradingbot has app/, base.py, web.py, ui_build/ after you copy your code."
fi
chown -R www-data:www-data /opt/tradingbot

# ---- Add auth router (only if missing) ----
if ! [ -f /opt/tradingbot/app/auth.py ]; then
  echo "[ADD] Installing app/auth.py"
  install -D -m 0644 /dev/stdin /opt/tradingbot/app/auth.py <<'PYCODE'
from __future__ import annotations
import os, json, time, hmac, hashlib, base64
from pathlib import Path
from typing import Optional
from fastapi import APIRouter, HTTPException, Request, Response, Depends
from fastapi.responses import JSONResponse, StreamingResponse
from pydantic import BaseModel
from passlib.context import CryptContext
import pyotp

router = APIRouter(prefix="/auth", tags=["auth"])

DATA_DIR = Path(os.environ.get("TB_RUNTIME_DIR") or Path.cwd() / "runtime")
DATA_DIR.mkdir(parents=True, exist_ok=True)
AUTH_FILE = DATA_DIR / "auth.json"

pwd_ctx = CryptContext(schemes=["bcrypt"], deprecated="auto")
COOKIE_NAME = "tb_session"
COOKIE_TTL = 60 * 60 * 8  # 8h

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
    return {"user": "admin", "password_hash": None, "totp_secret": None, "enrolled": False, "created_ts": _now(), "session_key": base64.urlsafe_b64encode(os.urandom(24)).decode()}

def _save_auth(data: dict):
    AUTH_FILE.write_text(json.dumps(data), encoding="utf-8")

class InitReq(BaseModel):
    new_password: str

@router.post("/init")
def init_account(body: InitReq):
    data = _load_auth()
    if data.get("password_hash"):
        raise HTTPException(400, "Already initialized")
    if len(body.new_password) < 8:
        raise HTTPException(400, "Password too short")
    data["password_hash"] = pwd_ctx.hash(body.new_password)
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
    issuer = "TradingBot"
    account = data.get("user","admin")
    uri = pyotp.totp.TOTP(secret).provisioning_uri(name=account, issuer_name=issuer)
    import qrcode, io
    buf = io.BytesIO()
    img = qrcode.make(uri)
    img.save(buf, format="PNG"); buf.seek(0)
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

class LoginReq(BaseModel):
    username: str
    password: str
    code: Optional[str] = None

@router.post("/login")
def login(body: LoginReq, response: Response):
    data = _load_auth()
    if not data.get("password_hash"):
        return JSONResponse({"ok": False, "stage": "init"}, status_code=403)
    if body.username != data.get("user") or not pwd_ctx.verify(body.password, data["password_hash"]):
        raise HTTPException(401, "Invalid credentials")
    if not data.get("enrolled"):
        return JSONResponse({"ok": False, "stage": "enroll"}, status_code=403)
    totp = pyotp.TOTP(data["totp_secret"])
    if not (body.code and totp.verify(body.code, valid_window=1)):
        raise HTTPException(401, "Invalid TOTP")
    session = _make_cookie(data["user"], data["session_key"])
    response.set_cookie(
        COOKIE_NAME, session, max_age=COOKIE_TTL, httponly=True,
        secure=(os.environ.get("TB_INSECURE_COOKIES")!="1"),
        samesite="Strict", path="/"
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
PYCODE
fi
chown -R www-data:www-data /opt/tradingbot/app

# ---- venv & deps (optional) ----
USE_VENV=0
if [[ -f /opt/tradingbot/requirements.txt ]]; then
  echo "[VENV] Installing Python deps"
  cd /opt/tradingbot
  python3 -m venv .venv
  chown -R www-data:www-data .venv
  # install as www-data so future pip installs also work
  sudo -u www-data -H /opt/tradingbot/.venv/bin/pip install --upgrade pip wheel
  sudo -u www-data -H /opt/tradingbot/.venv/bin/pip install -r requirements.txt
  USE_VENV=1
fi

# ---- IB Gateway runner ----
install -D -m 0755 /dev/stdin /opt/ibkr/run-ibgateway.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

export DISPLAY=${DISPLAY:-:1}
XVFB_W=${XVFB_W:-1280}
XVFB_H=${XVFB_H:-800}
XVFB_D=${XVFB_D:-24}

IB_HOME="${IB_HOME:-$HOME/Jts/ibgateway/1037}"
IB_BIN="${IB_BIN:-$IB_HOME/ibgateway}"
IBC_INI="${IBC_INI:-$HOME/.ibc/gateway-paper.ini}"

mkdir -p "$(dirname "$IBC_INI")"

cleanup() {
  pkill -f "websockify.*6080" || true
  pkill -f "x11vnc.*$DISPLAY" || true
  pkill -f "openbox" || true
  pkill -f "Xvfb $DISPLAY" || true
}
trap cleanup EXIT

if ! pgrep -f "Xvfb $DISPLAY" >/dev/null; then
  Xvfb $DISPLAY -screen 0 ${XVFB_W}x${XVFB_H}x${XVFB_D} -nolisten tcp &
  sleep 0.5
fi

if ! pgrep -f "openbox" >/dev/null; then
  openbox >/tmp/openbox.log 2>&1 &
  sleep 0.5
fi

if ! pgrep -f "x11vnc.*$DISPLAY" >/dev/null; then
  x11vnc -display $DISPLAY -localhost -forever -shared -rfbport 5901 -quiet &
  sleep 0.5
fi

if ! pgrep -f "websockify.*6080" >/dev/null; then
  websockify --web=/usr/share/novnc/ 127.0.0.1:6080 127.0.0.1:5901 >/tmp/websockify.log 2>&1 &
fi

if [ ! -f "$IBC_INI" ]; then
  cat > "$IBC_INI" <<CFG
[Login]
UseRemoteSettings=yes
LoginDialogDisplayTimeout=20
IbDir=${IB_HOME}
FIX=no
TradingMode=paper
MinimizeMainWindow=no
AcceptNonBrokerageAccountWarning=yes
ExitAfterAcceptingUserAgreement=no
OverrideTwsApiPort=4002
CFG
fi

"$IB_BIN" >/tmp/ibgateway.log 2>&1 &

while pgrep -f "ibgateway|Xvfb $DISPLAY|x11vnc.*$DISPLAY|websockify.*6080" >/dev/null; do
  sleep 2
done
BASH
chown -R ibkr:ibkr /opt/ibkr

# Install Gateway under ibkr
sudo -u ibkr bash -lc 'mkdir -p ~/Downloads && \
  (curl -fL -o ~/Downloads/ibgateway.sh https://download2.interactivebrokers.com/installers/ibgateway/stable-standalone/ibgateway-stable-standalone-linux-x64.sh || \
   curl -fL -o ~/Downloads/ibgateway.sh https://download2.interactivebrokers.com/installers/ibgateway/latest-standalone/ibgateway-latest-standalone-linux-x64.sh) && \
  chmod +x ~/Downloads/ibgateway.sh && \
  ~/Downloads/ibgateway.sh -q -dir $HOME/Jts/ibgateway/1037 || true'

# ---- Systemd: uvicorn + ibgateway ----
PYBIN="/usr/bin/python3"
if [[ $USE_VENV -eq 1 && -x /opt/tradingbot/.venv/bin/python ]]; then
  PYBIN="/opt/tradingbot/.venv/bin/python"
fi

if [[ $NO_TLS -eq 1 ]]; then
  cat > /etc/systemd/system/uvicorn.service <<UNIT
[Unit]
Description=Uvicorn TradingBot backend (FastAPI)
After=network-online.target

[Service]
Type=simple
User=www-data
WorkingDirectory=/opt/tradingbot
Environment=TB_RUNTIME_DIR=/opt/tradingbot/runtime
Environment=TB_INSECURE_COOKIES=1
ExecStart=$PYBIN -m uvicorn app.web:app --host 127.0.0.1 --port 8000
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT
else
  cat > /etc/systemd/system/uvicorn.service <<UNIT
[Unit]
Description=Uvicorn TradingBot backend (FastAPI)
After=network-online.target

[Service]
Type=simple
User=www-data
WorkingDirectory=/opt/tradingbot
Environment=TB_RUNTIME_DIR=/opt/tradingbot/runtime
ExecStart=$PYBIN -m uvicorn app.web:app --host 127.0.0.1 --port 8000
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT
fi

cat > /etc/systemd/system/ibgateway.service <<'UNIT'
[Unit]
Description=IBKR Gateway headless (Xvfb + x11vnc + websockify)
After=network-online.target

[Service]
Type=simple
User=ibkr
Environment=DISPLAY=:1
Environment=XVFB_W=1400
Environment=XVFB_H=900
ExecStart=/opt/ibkr/run-ibgateway.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now ibgateway.service
systemctl enable --now uvicorn.service

# ---- Nginx site (HTTP dev vs HTTPS prod) ----
if [[ $NO_TLS -eq 1 ]]; then
  cat > /etc/nginx/sites-available/tradingbot <<'NGINX'
server {
    listen 80;
    server_name $DOMAIN;

    # Auth gate
    location = /auth/validate {
        proxy_pass http://127.0.0.1:8000/auth/validate;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-Proto http;
    }

    location / {
        auth_request /auth/validate;
        error_page 401 = @unauth;
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-Proto http;
    }

    location @unauth {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-Proto http;
    }

    # noVNC static
    location /novnc/ {
        auth_request /auth/validate;
        alias /usr/share/novnc/;
        autoindex off;
    }

    # websockify (noVNC WebSocket)
    location /websockify {
        auth_request /auth/validate;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_pass http://127.0.0.1:6080;
    }

    # ACME (not used in --no-tls, but harmless)
    location ^~ /.well-known/acme-challenge/ {
        root /var/www/html;
        try_files $uri =404;
        allow all;
    }
}
NGINX
else
  cat > /etc/nginx/sites-available/tradingbot <<NGINX
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    # Filled by Certbot later
    ssl_certificate     /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    location = /auth/validate {
        proxy_pass http://127.0.0.1:8000/auth/validate;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-Proto https;
    }

    location / {
        auth_request /auth/validate;
        error_page 401 = @unauth;
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-Proto https;
    }

    location @unauth {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-Proto https;
    }

    location /novnc/ {
        auth_request /auth/validate;
        alias /usr/share/novnc/;
        autoindex off;
    }

    location /websockify {
        auth_request /auth/validate;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_pass http://127.0.0.1:6080;
    }

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/html;
        try_files \$uri =404;
        allow all;
    }
}
NGINX
fi

ln -sf /etc/nginx/sites-available/tradingbot /etc/nginx/sites-enabled/tradingbot
rm -f /etc/nginx/sites-enabled/default || true
nginx -t && systemctl reload nginx

if [[ $NO_TLS -eq 0 ]]; then
  certbot --nginx -d "$DOMAIN" -m "$EMAIL" --agree-tos --no-eff-email -n || true
  systemctl reload nginx
else
  echo "[DEV] Running without TLS. Cookies allowed over HTTP via TB_INSECURE_COOKIES=1 in uvicorn service."
fi

echo "---------------------------------------------"
if [[ $NO_TLS -eq 1 ]]; then
  echo "Install complete (DEV, HTTP). Open:  http://$DOMAIN"
else
  echo "Install complete (PROD, HTTPS). Open: https://$DOMAIN"
fi
echo "First run: set password -> scan TOTP QR -> enter code -> login."
echo "Settings page will show the IBKR gateway console (noVNC)."
