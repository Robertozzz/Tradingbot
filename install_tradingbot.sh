#!/usr/bin/env bash
# install_tradingbot.sh
# One-shot installer for Debian 12/13 (no GUI).
# Sets up: FastAPI (uvicorn), auth (password + TOTP), Nginx (+TLS optional),
# noVNC + websockify, and IBKR Gateway (Xvfb + openbox + x11vnc).
#
# Usage (pick ONE source method):
#   sudo bash install_tradingbot.sh --domain bot.example.com --email you@example.com \
#     --git https://github.com/you/your-tradingbot.git --ref main
#   # OR
#   # Dev mode (HTTP only, no TLS):
#   sudo bash install_tradingbot.sh --no-tls --domain myvm.local --email you@example.com \
#     --git https://github.com/you/your-tradingbot.git --ref main

set -euo pipefail

# ---- Args ----
DOMAIN=""
EMAIL=""
ZIP_SRC=""
GIT_URL=""
# Default ref if none provided: main
GIT_REF="main"
NO_TLS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN="$2"; shift 2 ;;
    --email) EMAIL="$2"; shift 2 ;;
    --zip) ZIP_SRC="$2"; shift 2 ;;
    --git) GIT_URL="$2"; shift 2 ;;
    # Preferred: can be branch, tag, or commit SHA
    --ref) GIT_REF="$2"; shift 2 ;;
    # Back-compat aliases
    --branch) GIT_REF="$2"; shift 2 ;;
    --commit) GIT_REF="$2"; shift 2 ;;
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

# Install tools required to add external repos/keys first
apt-get install -y gnupg ca-certificates curl

# ---- Xpra APT repo (needed on Debian 13 / trixie; falls back to bookworm) ----
install -d -m 0755 /etc/apt/keyrings
rm -f /etc/apt/keyrings/xpra.gpg
curl -fsSL https://xpra.org/gpg.asc | gpg --dearmor --batch --yes -o /etc/apt/keyrings/xpra.gpg
chmod 0644 /etc/apt/keyrings/xpra.gpg
# Detect codename, fall back if xpra.org doesn't serve it yet
. /etc/os-release
XPRA_CODENAME="${VERSION_CODENAME:-bookworm}"
if ! curl -fsSI "https://xpra.org/dists/$XPRA_CODENAME/" >/dev/null; then
  XPRA_CODENAME=bookworm
fi
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/xpra.gpg] https://xpra.org/ $XPRA_CODENAME main" \
 | sudo tee /etc/apt/sources.list.d/xpra.list

# Refresh indices now that xpra.org is added
apt-get update

apt-get install -y \
  python3 python3-venv python3-pip python3-uvicorn python3-fastapi \
  python3-passlib python3-pyotp python3-qrcode \
  unzip curl ca-certificates git rsync \
  xpra xvfb wmctrl xdotool \
  nginx certbot python3-certbot-nginx \
  libgtk-3-0 libglib2.0-0 libpango-1.0-0 libcairo2 libgdk-pixbuf-2.0-0 \
  libxcomposite1 libxdamage1 libxfixes3 libxss1 libxtst6 libxi6 libxrandr2 \
  libnss3 libasound2 libatk1.0-0 libatk-bridge2.0-0 libcups2 \
  libx11-xcb1 libxcb1 libxcb-render0 libxcb-shm0 libdrm2 libgbm1 \
  libfontconfig1 fonts-dejavu-core jq
  
# Prevent Debian's Xpra socket-activation from grabbing 14500:
systemctl stop    xpra-server.socket xpra.socket 2>/dev/null || true
systemctl disable xpra-server.socket xpra.socket 2>/dev/null || true
systemctl mask    xpra-server.socket xpra.socket 2>/dev/null || true
systemctl stop    xpra-server.service xpra-proxy.service 2>/dev/null || true
systemctl disable xpra-server.service xpra-proxy.service 2>/dev/null || true
systemctl mask    xpra-proxy.service 2>/dev/null || true
pkill -f 'xpra (proxy|start)' 2>/dev/null || true

# ---- Users / dirs ----
id -u ibkr >/dev/null 2>&1 || useradd -m -s /bin/bash ibkr
install -d -o root -g root -m 0755 /opt
install -d -o www-data -g www-data -m 0755 /opt/tradingbot
install -d -o www-data -g www-data -m 0755 /opt/tradingbot/runtime
install -d -o www-data -g www-data -m 0755 /opt/tradingbot/logs

# Reuse heavy dirs on re-runs (don’t delete these during rsync)
RSYNC_EXCLUDES=(--exclude='.venv/' --exclude='runtime/' --exclude='logs/')

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
  rsync -av --delete "${RSYNC_EXCLUDES[@]}" "$SRC_ROOT"/ /opt/tradingbot/
elif [[ -n "$GIT_URL" ]]; then
  echo "[GIT] Fetching ref '$GIT_REF' from $GIT_URL"
  mkdir -p "$TMPD/repo"
  git -C "$TMPD/repo" init -q
  git -C "$TMPD/repo" remote add origin "$GIT_URL"
  # Try shallow fetch of the specific ref (works for branch, tag, or reachable commit SHA).
  if git -C "$TMPD/repo" fetch -q --depth 1 origin "$GIT_REF"; then
    git -C "$TMPD/repo" -c advice.detachedHead=false checkout -q --detach FETCH_HEAD
  else
    echo "[GIT] Shallow fetch failed, falling back to full fetch of ref '$GIT_REF'..."
    git -C "$TMPD/repo" fetch -q origin "$GIT_REF"
    git -C "$TMPD/repo" -c advice.detachedHead=false checkout -q --detach FETCH_HEAD
  fi
  echo "[GIT] Using commit $(git -C "$TMPD/repo" rev-parse --short HEAD)"
  # Be verbose about what changes are being copied over
  rsync -ai --delete "${RSYNC_EXCLUDES[@]}" "$TMPD/repo"/ /opt/tradingbot/
else
  echo "[SKIP] Using empty skeleton; ensure /opt/tradingbot has app/, base.py, web.py, ui_build/ after you copy your code."
fi
chown -R www-data:www-data /opt/tradingbot
chown -R www-data:www-data /opt/tradingbot/app

# ---- venv & deps (optional) ----
USE_VENV=0
if [[ -f /opt/tradingbot/requirements.txt ]]; then
  echo "[VENV] Using/creating Python venv"
  cd /opt/tradingbot
  if [[ ! -d .venv ]]; then
    python3 -m venv .venv
    chown -R www-data:www-data .venv
  fi

  # setup pip cache dir inside app path (owned by www-data)
  export PIP_CACHE_DIR=/opt/tradingbot/.cache/pip
  install -d -o www-data -g www-data -m 700 "$PIP_CACHE_DIR"

  # install/upgrade only what’s needed; fast on re-runs
  sudo -u www-data -H env PIP_CACHE_DIR=$PIP_CACHE_DIR \
    /opt/tradingbot/.venv/bin/pip install --upgrade pip wheel
  sudo -u www-data -H env PIP_CACHE_DIR=$PIP_CACHE_DIR \
    /opt/tradingbot/.venv/bin/pip install --upgrade -r requirements.txt --upgrade-strategy only-if-needed
  USE_VENV=1
fi

# ---- IB Gateway runner with XPRA (HTML5, seamless windows) ----
install -D -m 0755 /dev/stdin /opt/ibkr/run-ibgateway-xpra.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

XPRA_PORT=${XPRA_PORT:-14500}
DISPLAY_ID=${DISPLAY_ID:-100}

IB_HOME="${IB_HOME:-$HOME/Jts/ibgateway/1037}"
IB_BIN="${IB_BIN:-$IB_HOME/ibgateway}"

# xpra serves the HTML5 client itself; we proxy /xpra/ to 127.0.0.1:$XPRA_PORT
exec xpra start ":${DISPLAY_ID}" \
  --daemon=no \
  --html=on \
  --bind-tcp=127.0.0.1:${XPRA_PORT} \
  --exit-with-children=yes \
  --start-child="${IB_BIN}" \
  --speaker=off --microphone=off --pulseaudio=no \
  --printing=no --clipboard=yes --mdns=no
BASH
chown -R ibkr:ibkr /opt/ibkr

# Install Gateway under ibkr (idempotent)
# We use the same path as the runner script: $HOME/Jts/ibgateway/1037
sudo -u ibkr bash -lc '
  set -euo pipefail
  IB_DIR="$HOME/Jts/ibgateway/1037"
  IB_BIN="$IB_DIR/ibgateway"
  if [[ -x "$IB_BIN" ]]; then
    echo "[IBKR] Found existing IB Gateway at $IB_BIN — skipping download/install."
  else
    echo "[IBKR] Installing IB Gateway into $IB_DIR ..."
    mkdir -p ~/Downloads
    # Cache the installer to avoid re-downloading on failures/retries
    INST_SH=~/Downloads/ibgateway.sh
    if [[ ! -s "$INST_SH" ]]; then
      curl -fL -o "$INST_SH" https://download2.interactivebrokers.com/installers/ibgateway/stable-standalone/ibgateway-stable-standalone-linux-x64.sh || \
      curl -fL -o "$INST_SH" https://download2.interactivebrokers.com/installers/ibgateway/latest-standalone/ibgateway-latest-standalone-linux-x64.sh
      chmod +x "$INST_SH"
    fi
    "$INST_SH" -q -dir "$IB_DIR" || true
  fi
'
  
# (Openbox/Xvfb/noVNC not needed with xpra)

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
Environment=IB_HOST=127.0.0.1
Environment=IB_PORT=4002
Environment=IB_CLIENT_ID=11
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
Environment=IB_HOST=127.0.0.1
Environment=IB_PORT=4001
Environment=IB_CLIENT_ID=11
ExecStart=$PYBIN -m uvicorn app.web:app --host 127.0.0.1 --port 8000
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT
fi

## Old ibgateway.service (Xvfb + noVNC) is replaced by xpra:
## stop/disable if it exists
systemctl disable --now ibgateway.service 2>/dev/null || true

# /etc/systemd/system/xpra-ibgateway.service
cat > /etc/systemd/system/xpra-ibgateway.service <<'UNIT'
[Unit]
Description=Xpra session for IB Gateway (window-only streaming)
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=ibkr
# Give xpra a writable runtime dir:
RuntimeDirectory=xpra-ibgateway
Environment=XDG_RUNTIME_DIR=/run/xpra-ibgateway
Environment=DISPLAY=:100
# Foreground server with HTML5 bound to loopback:14500
ExecStart=/usr/bin/xpra start :100 \
  --daemon=no \
  --html=on \
  --bind-tcp=127.0.0.1:14500 \
  --exit-with-children=yes \
  --start-child=/home/ibkr/Jts/ibgateway/1037/ibgateway \
  --speaker=off --microphone=off --pulseaudio=no \
  --printing=no --clipboard=yes --mdns=no
ExecStop=/usr/bin/xpra stop :100 --wait=yes
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now xpra-ibgateway.service
systemctl restart xpra-ibgateway.service || true
systemctl enable --now uvicorn.service

# ---- Nginx site (HTTP dev vs HTTPS prod) ----
if [[ $NO_TLS -eq 1 ]]; then
  cat > /etc/nginx/sites-available/tradingbot <<NGINX
server {
    listen 80;
    server_name $DOMAIN;
	
    # Serve a simple iframe test page from same-origin:
    location = /xpra_iframe_test.html {
        auth_request off;
        root /var/www/html;
        default_type text/html;
    }

    # /xpra without trailing slash -> /xpra/
    location = /xpra { return 301 /xpra/; }

    # Auth gate
    location = /auth/validate {
        proxy_pass http://127.0.0.1:8000/auth/validate;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-Proto http;
    }

    location / {
        auth_request /auth/validate;
        error_page 401 = @unauth;
        # Allow our app pages to embed same-origin iframes (like /xpra/)
        proxy_hide_header Content-Security-Policy;
        add_header Content-Security-Policy "frame-ancestors 'self' http://\$host https://\$host; frame-src 'self' http://\$host https://\$host; child-src 'self' http://\$host https://\$host" always;
        add_header X-Frame-Options "SAMEORIGIN" always;
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-Proto http;
    }

    location @unauth {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-Proto http;
    }
	
    # XPRA HTML5 (IB Gateway windows) - no auth gate (iframe+WS)
    location /xpra/ {
        auth_request off;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 86400;
        proxy_buffering off;
        # allow embedding: drop upstream blocking headers and set permissive ones
        proxy_hide_header X-Frame-Options;
        proxy_hide_header Content-Security-Policy;
        add_header X-Frame-Options "SAMEORIGIN" always;
        add_header Content-Security-Policy "frame-ancestors 'self' http://\$host https://\$host" always;

        # strip the /xpra/ prefix so Xpra’s absolute paths (/connect, /favicon.ico, etc) resolve
        rewrite ^/xpra/(.*)$ /\$1 break;
        # and rewrite any absolute redirect back under /xpra/ for the browser
        proxy_redirect ~^(/.*)$ /xpra\$1;
        proxy_pass http://127.0.0.1:14500;
    }

    # Xpra websocket uses absolute /connect - no auth gate
    location /connect {
        auth_request off;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 86400;
        proxy_buffering off;
        proxy_hide_header X-Frame-Options;
        proxy_hide_header Content-Security-Policy;
        proxy_pass http://127.0.0.1:14500;
    }
	
    # Xpra absolute-path assets (no auth gate)
    location = /favicon.ico {
        auth_request off;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_read_timeout 86400;
        proxy_buffering off;
        proxy_hide_header X-Frame-Options;
        proxy_hide_header Content-Security-Policy;
        proxy_pass http://127.0.0.1:14500;
    }
	
    location ^~ /client/ {
        auth_request off;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_read_timeout 86400;
        proxy_buffering off;
        proxy_hide_header X-Frame-Options;
        proxy_hide_header Content-Security-Policy;
        proxy_pass http://127.0.0.1:14500;
    }
	
    location ^~ /resources/ {
        auth_request off;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_read_timeout 86400;
        proxy_buffering off;
        proxy_hide_header X-Frame-Options;
        proxy_hide_header Content-Security-Policy;
        proxy_pass http://127.0.0.1:14500;
    }

    # noVNC static
    location /novnc/ {
        auth_request /auth/validate;
        alias /usr/share/novnc/;
        autoindex off;
    }

# (legacy noVNC websocket removed; xpra handles HTML+WS itself)

    # ACME (not used in --no-tls, but harmless)
    location ^~ /.well-known/acme-challenge/ {
        root /var/www/html;
        try_files \$uri =404;
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
	
    # /xpra without trailing slash -> /xpra/
    location = /xpra { return 301 /xpra/; }

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
        # Match the relaxed CSP on unauth redirect target too
        proxy_hide_header Content-Security-Policy;
        add_header Content-Security-Policy "frame-ancestors 'self' http://\$host https://\$host; frame-src 'self' http://\$host https://\$host; child-src 'self' http://\$host https://\$host" always;
        add_header X-Frame-Options "SAMEORIGIN" always;
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

    # XPRA HTML5 (IB Gateway windows) - no auth gate (iframe+WS)
    location /xpra/ {
        auth_request off;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 86400;
        proxy_buffering off;
        # allow embedding: drop upstream blocking headers and set permissive ones
        proxy_hide_header X-Frame-Options;
        proxy_hide_header Content-Security-Policy;
        add_header X-Frame-Options "SAMEORIGIN" always;
        add_header Content-Security-Policy "frame-ancestors 'self' http://\$host https://\$host" always;
        # strip the /xpra/ prefix so Xpra’s absolute paths (/connect, /favicon.ico, etc) resolve
        rewrite ^/xpra/(.*)$ /\$1 break;
        # and rewrite any absolute redirect back under /xpra/ for the browser
        proxy_redirect ~^(/.*)$ /xpra\$1;
        proxy_pass http://127.0.0.1:14500;
    }

    # Xpra websocket uses absolute /connect - no auth gate
    location /connect {
        auth_request off;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 86400;
        proxy_buffering off;
        proxy_hide_header X-Frame-Options;
        proxy_hide_header Content-Security-Policy;
        proxy_pass http://127.0.0.1:14500;
    }
	
    # Xpra absolute-path assets (no auth gate)
    location = /favicon.ico {
        auth_request off;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_read_timeout 86400;
        proxy_buffering off;
        proxy_hide_header X-Frame-Options;
        proxy_hide_header Content-Security-Policy;
        proxy_pass http://127.0.0.1:14500;
    }
    location ^~ /client/ {
        auth_request off;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_read_timeout 86400;
        proxy_buffering off;
        proxy_hide_header X-Frame-Options;
        proxy_hide_header Content-Security-Policy;
        proxy_pass http://127.0.0.1:14500;
    }
    location ^~ /resources/ {
        auth_request off;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_read_timeout 86400;
        proxy_buffering off;
        proxy_hide_header X-Frame-Options;
        proxy_hide_header Content-Security-Policy;
        proxy_pass http://127.0.0.1:14500;
    }

    # (legacy noVNC websocket removed; xpra handles HTML+WS itself)

    location /novnc/ {
        auth_request /auth/validate;
        alias /usr/share/novnc/;
        autoindex off;
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

web.py:
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


test html:
sudo tee /var/www/html/xpra_iframe_test.html >/dev/null <<'HTML'
<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <title>Xpra iframe test</title>
  <style>html,body,#wrap{height:100%;margin:0}</style>
</head>
<body>
  <div id="wrap">
    <iframe
      id="xpra"
      src="http://192.168.133.130/xpra/"
      style="width:100%;height:100%;border:0"
      allow="clipboard-read; clipboard-write; fullscreen *"
      allowfullscreen>
    </iframe>
  </div>
</body>
</html>
HTML

