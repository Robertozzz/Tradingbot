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

    # /xpra (no trailing slash) : proxy directly (avoid 301 in iframes)
    location = /xpra {
        # no auth gate for xpra bits
        auth_request off;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_read_timeout 86400;
        proxy_buffering off;
        # allow embedding: drop upstream blocking headers and set permissive ones
        proxy_hide_header X-Frame-Options;
        proxy_hide_header Content-Security-Policy;
        add_header X-Frame-Options "SAMEORIGIN" always;
        add_header Content-Security-Policy "frame-ancestors 'self' http://$host https://$host" always;
        # map /xpra -> / at the upstream
        rewrite ^/xpra$ / break;
        # and rewrite any absolute redirect back under /xpra/ for the browser
        proxy_redirect ~^(/.*)$ /xpra$1;
        proxy_pass http://127.0.0.1:14500;
    }

    # Auth gate
    location = /auth/validate {
        proxy_pass http://127.0.0.1:8000/auth/validate;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-Proto http;
    }

    location / {
        auth_request off;
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
	
    # /xpra (no trailing slash) : proxy directly (avoid 301 in iframes)
    location = /xpra {
        auth_request off;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_read_timeout 86400;
        proxy_buffering off;
        # allow embedding
        proxy_hide_header X-Frame-Options;
        proxy_hide_header Content-Security-Policy;
        add_header X-Frame-Options "SAMEORIGIN" always;
        add_header Content-Security-Policy "frame-ancestors 'self' http://$host https://$host" always;
        # map /xpra -> / upstream
        rewrite ^/xpra$ / break;
        proxy_redirect ~^(/.*)$ /xpra$1;
        proxy_pass http://127.0.0.1:14500;
    }

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
        auth_request off;
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