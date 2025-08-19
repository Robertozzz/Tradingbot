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
  xvfb openbox x11vnc novnc websockify wmctrl xdotool \
  nginx certbot python3-certbot-nginx \
  libgtk-3-0 libglib2.0-0 libpango-1.0-0 libcairo2 libgdk-pixbuf-2.0-0 \
  libxcomposite1 libxdamage1 libxfixes3 libxss1 libxtst6 libxi6 libxrandr2 \
  libnss3 libasound2 libatk1.0-0 libatk-bridge2.0-0 libcups2 \
  libx11-xcb1 libxcb1 libxcb-render0 libxcb-shm0 libdrm2 libgbm1 \
  libfontconfig1 fonts-dejavu-core jq

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
  rsync -a --delete "${RSYNC_EXCLUDES[@]}" "$SRC_ROOT"/ /opt/tradingbot/
elif [[ -n "$GIT_URL" ]]; then
  git clone --depth 1 --branch "$GIT_BRANCH" "$GIT_URL" "$TMPD/repo"
  rsync -a --delete "${RSYNC_EXCLUDES[@]}" "$TMPD/repo"/ /opt/tradingbot/
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
  # install/upgrade only what’s needed; fast on re-runs
  sudo -u www-data -H /opt/tradingbot/.venv/bin/pip install --upgrade pip wheel
  sudo -u www-data -H /opt/tradingbot/.venv/bin/pip install --upgrade -r requirements.txt --upgrade-strategy only-if-needed

  USE_VENV=1
fi

# ---- IB Gateway runner ----
install -D -m 0755 /dev/stdin /opt/ibkr/run-ibgateway.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

export DISPLAY=${DISPLAY:-:1}
XVFB_W=${XVFB_W:-800}
XVFB_H=${XVFB_H:-610}
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
  x11vnc -display $DISPLAY \
         -localhost -forever -shared \
         -rfbport 5901 -quiet \
         -noxdamage -noxrecord -xkb -repeat \
         -cursor most &
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
  
# ---- Openbox tweaks: single desktop, no wheel-switching, maximize IB Gateway ----
sudo -u ibkr mkdir -p /home/ibkr/.config/openbox
sudo -u ibkr tee /home/ibkr/.config/openbox/rc.xml >/dev/null <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_config xmlns="http://openbox.org/3.4/rc">
  <desktops>
    <number>1</number>
    <firstdesk>1</firstdesk>
  </desktops>
  <mouse>
    <dragThreshold>8</dragThreshold>
    <doubleClickTime>200</doubleClickTime>
    <screenEdgeStrength>0</screenEdgeStrength>
    <!-- Disable wheel to change desktop on background -->
    <context name="Root">
      <mousebind button="Up" action="Click"/>
      <mousebind button="Down" action="Click"/>
    </context>
  </mouse>
  <theme>
    <name>Clearlooks</name>
    <titleLayout>NLIMC</titleLayout>
  </theme>
  <applications/>
</openbox_config>
XML
sudo -u ibkr tee /home/ibkr/.config/openbox/autostart >/dev/null <<'SH'
(sleep 8; wmctrl -r "IB Gateway" -b add,maximized_vert,maximized_horz) &
SH
sudo chmod +x /home/ibkr/.config/openbox/autostart

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

cat > /etc/systemd/system/ibgateway.service <<'UNIT'
[Unit]
Description=IBKR Gateway headless (Xvfb + x11vnc + websockify)
After=network-online.target

[Service]
Type=simple
User=ibkr
Environment=DISPLAY=:1
Environment=XVFB_W=800
Environment=XVFB_H=610
ExecStart=/opt/ibkr/run-ibgateway.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now ibgateway.service
systemctl restart ibgateway.service || true
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