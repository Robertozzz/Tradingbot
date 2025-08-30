#!/usr/bin/env bash
# install_tradingbot.sh
# One-shot installer for Debian 12/13 (no GUI).
# Sets up: FastAPI (uvicorn), auth (password + TOTP), Nginx (+TLS optional),
# Xpra (HTML5) and IBKR Gateway via IBC (auto-login).
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
  unzip curl ca-certificates git rsync openbox \
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
install -d -o www-data -g www-data -m 0755 /opt/tradingbot/app
install -d -o www-data -g www-data -m 0755 /opt/tradingbot/static/xpra
install -d -o root -g root -m 0755 /opt/ibc
# ibkr should be able to write logs shared with www-data
usermod -aG www-data ibkr || true
chmod 0775 /opt/tradingbot/logs

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

# ---- Remove legacy standalone xpra runner if present (prevents port clashes) ----
rm -f /opt/ibkr/run-ibgateway-xpra.sh 2>/dev/null || true

# ---- Helper: pin IBKR window to top-left without resizing ----
install -D -m 0755 /dev/stdin /usr/local/bin/pin-ibgw.sh <<'PINSH'
#!/usr/bin/env bash
set -euo pipefail
exit 0
PINSH

chown root:root /usr/local/bin/pin-ibgw.sh

# Install Gateway under ibkr (idempotent)
# Install into ~/Jts and let IB's installer create ibgateway/<version>/ automatically
sudo -u ibkr bash -lc '
  set -euo pipefail
  JTS_DIR="$HOME/Jts"
  if find "$JTS_DIR/ibgateway" -maxdepth 2 -type f -name ibgateway -print -quit >/dev/null 2>&1; then
    echo "[IBKR] Found existing IB Gateway under $JTS_DIR/ibgateway — skipping download/install."
  else
    echo "[IBKR] Installing IB Gateway into $JTS_DIR ..."
    mkdir -p ~/Downloads
    # Cache the installer to avoid re-downloading on failures/retries
    INST_SH=~/Downloads/ibgateway.sh
    if [[ ! -s "$INST_SH" ]]; then
      curl -fL -o "$INST_SH" https://download2.interactivebrokers.com/installers/ibgateway/stable-standalone/ibgateway-stable-standalone-linux-x64.sh || \
      curl -fL -o "$INST_SH" https://download2.interactivebrokers.com/installers/ibgateway/latest-standalone/ibgateway-latest-standalone-linux-x64.sh
      chmod +x "$INST_SH"
    fi
    "$INST_SH" -q -dir "$JTS_DIR" || true
  fi
'
  
# ---- Install IBC (IBController) ------------------------------------------------
if [[ ! -x /opt/ibc/gatewaystart.sh ]]; then
  echo "[IBC] Installing IBC to /opt/ibc ..."
  TMPIB="$(mktemp -d)"
  set +e
  curl -fL https://github.com/IbcAlpha/IBC/releases/download/3.23.0/IBCLinux-3.23.0.zip -o "$TMPIB/IBC.zip"
  set -e
  unzip -q "$TMPIB/IBC.zip" -d "$TMPIB/ibc"
  rsync -a "$TMPIB/ibc"/ /opt/ibc/
  chmod -R a+rx /opt/ibc
fi

# ---- IBC start wrapper (bypass gatewaystart.sh; pass env directly) ----
install -D -m 0755 /dev/stdin /opt/ibc/start-ibc.sh <<'IBWRAP'
#!/usr/bin/env bash
set -euo pipefail

cd "${HOME:-/home/ibkr}"

# Auto-detect newest installed IB Gateway major version (fallback 1037):
IB_ROOT="$HOME/Jts/ibgateway"
if LATEST_DIR="$(ls -1d "${IB_ROOT}"/* 2>/dev/null | sort -V | tail -n1)"; then
  export TWS_MAJOR_VRSN="${LATEST_DIR##*/}"
else
  export TWS_MAJOR_VRSN=1037
fi

# Standard IBC env (config + logs + paths)
export IBC_PATH=/opt/ibc
export IBC_INI=/opt/ibc/config.ini
export TWS_PATH="$HOME/Jts"
export LOG_PATH=/opt/tradingbot/logs

# Map our mode variable into what IBC expects:
export TRADING_MODE="${IB_MODE:-paper}"

# Call the low-level launcher directly so our env is honored
# (gatewaystart.sh hard-sets defaults like TWS_MAJOR_VRSN=1019).
exec /opt/ibc/scripts/displaybannerandlaunch.sh
IBWRAP
chown ibkr:ibkr /opt/ibc/start-ibc.sh

# Minimal IBC config (backend can keep in sync)
if [[ ! -f /opt/ibc/config.ini ]]; then
  cat > /opt/ibc/config.ini <<'IBCINI'
IbLoginId=
IbPassword=
TradingMode=
TwoFactorMethod=none
# TwoFactorSecret=
AcceptNonBrokerageAccountWarning=yes
MinimizeMainWindow=yes
IbDir=
IBCPath=/opt/ibc
GatewayOrTws=gateway
IBCLogs=/opt/tradingbot/logs
IBCINI
  # Backend (www-data) must be able to update creds/TOTP; IBC (user ibkr) must read it.
  chown www-data:ibkr /opt/ibc/config.ini
  chmod 640 /opt/ibc/config.ini
fi

# Runtime env used by API/UI to update creds/mode without editing units
install -d -o www-data -g www-data -m 0755 /opt/tradingbot/runtime
if [[ ! -f /opt/tradingbot/runtime/ibc.env ]]; then
  cat > /opt/tradingbot/runtime/ibc.env <<'ENVV'
# Filled/maintained by API (e.g., /ibkr/ibc/config)
IB_USER=
IB_PASSWORD=
IB_TOTP_SECRET=
# 'paper' or 'live'
IB_MODE=paper
# default ports: live=4001, paper=4002
IB_PORT=4002
# single-session display
DISPLAY=:100
ENVV
  chown www-data:www-data /opt/tradingbot/runtime/ibc.env
  chmod 600 /opt/tradingbot/runtime/ibc.env || true
fi

# Nginx toggle for /xpra-main/ visibility (0=hidden, 1=visible)
if [[ ! -f /opt/tradingbot/runtime/xpra_main_enabled.conf ]]; then
  echo 'set $xpra_main_enabled 0;' > /opt/tradingbot/runtime/xpra_main_enabled.conf
  chown www-data:www-data /opt/tradingbot/runtime/xpra_main_enabled.conf
fi

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
EnvironmentFile=/opt/tradingbot/runtime/ibc.env
Environment=TB_RUNTIME_DIR=/opt/tradingbot/runtime
Environment=IB_HOST=127.0.0.1
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
EnvironmentFile=/opt/tradingbot/runtime/ibc.env
Environment=TB_RUNTIME_DIR=/opt/tradingbot/runtime
Environment=IB_HOST=127.0.0.1
Environment=IB_CLIENT_ID=11
ExecStart=$PYBIN -m uvicorn app.web:app --host 127.0.0.1 --port 8000
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT
fi

# Stop/disable any legacy single xpra unit if present
systemctl disable --now ibgateway.service 2>/dev/null || true

# /etc/systemd/system/xpra-ibgateway-main.service
cat > /etc/systemd/system/xpra-ibgateway-main.service <<'UNIT'
[Unit]
Description=Xpra session for IB Gateway main (via IBC)
After=network-online.target

[Service]
User=ibkr
WorkingDirectory=/home/ibkr
Environment=HOME=/home/ibkr
RuntimeDirectory=xpra-main
Environment=XDG_RUNTIME_DIR=/run/xpra-main
EnvironmentFile=/opt/tradingbot/runtime/ibc.env
ExecStartPre=/usr/bin/install -d -o ibkr -g ibkr -m 700 /run/xpra-main/xpra
ExecStartPre=/usr/bin/bash -lc "xpra stop :100 || true"
ExecStart=/usr/bin/xpra start :100 \
  --daemon=no --html=on \
  --speaker=off \
  --microphone=off \
  --pulseaudio=no \
  --bell=off \
  --bind-tcp=127.0.0.1:14500 \
  --dpi=96 \
  --exit-with-children=no \
  --log-file=/home/ibkr/xpra-main.log \
  --start-child=/usr/bin/openbox \
  --start-child=/opt/ibc/start-ibc.sh \
  --start-child=/usr/local/bin/pin-ibgw.sh
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
UNIT

# Allow backend (www-data) to toggle visibility and restart xpra safely
cat >/etc/sudoers.d/tradingbot-ibc <<'SUD'
www-data ALL=(ALL) NOPASSWD: /bin/systemctl restart xpra-ibgateway-main.service
www-data ALL=(ALL) NOPASSWD: /bin/systemctl start xpra-ibgateway-main.service
www-data ALL=(ALL) NOPASSWD: /bin/systemctl stop xpra-ibgateway-main.service
www-data ALL=(ALL) NOPASSWD: /usr/sbin/nginx -t
www-data ALL=(ALL) NOPASSWD: /bin/systemctl reload nginx
# Allow switching paper/live (port) by restarting the app when /ibkr/ibc/config changes it
www-data ALL=(ALL) NOPASSWD: /bin/systemctl restart uvicorn.service
SUD
chmod 440 /etc/sudoers.d/tradingbot-ibc

systemctl daemon-reload
systemctl enable --now xpra-ibgateway-main.service
systemctl restart xpra-ibgateway-main.service || true
sleep 1
systemctl enable --now uvicorn.service

# ---- Nginx site (HTTP dev vs HTTPS prod) ----
if [[ $NO_TLS -eq 1 ]]; then
  cat > /etc/nginx/sites-available/tradingbot <<NGINX
server {
    listen 80;
    server_name $DOMAIN _;

    # convenience redirects without trailing slash
    location = /xpra-main { return 301 /xpra-main/; }

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
	
    # XPRA HTML5 MAIN (no auth gate; iframe+WS)
    location /xpra-main/ {
        auth_request off;
        # Viewer toggle (0=hidden => 404; 1=visible)
        set \$xpra_main_enabled 0;
        include /opt/tradingbot/runtime/xpra_main_enabled.conf;
        if (\$xpra_main_enabled = 0) {
            return 404;
        }
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

        # allow HTML rewrite + strip meta CSP
        proxy_set_header Accept-Encoding "";
        sub_filter_types text/html;
        sub_filter_once off;
        sub_filter '<meta http-equiv="Content-Security-Policy"' '<meta http-equiv="x-removed-CSP">';
        # nudge view to top-left on load just in case
        sub_filter '<body>' '<body><script>try{scrollTo(0,0)}catch(e){}</script>';

        # hide Xpra chrome, transparent background
        sub_filter '</head>' '<style id="xpra-embed">
          #toolbar,#menubar,#footer,#taskbar,#sidepanel,#notifications{display:none!important}
          html,body,#workspace{margin:0;padding:0;width:100%;height:100%;background:transparent}
          .window{box-shadow:none!important;border:none!important}
        </style></head>';

        # emit size of first app window (or canvas) to parent, ensure native pixels (no scaling)
        sub_filter '</body>' '<script>
		  (function(){
			try{ if(!/scaling=/.test(location.search)) history.replaceState(null,"",location.pathname+"?scaling=off"); }catch(e){}
			function findTarget(){
			  // Xpra v17: windows are ".window"; before that, at least a #screen canvas exists
			  return document.querySelector(".window") || document.querySelector("#screen canvas");
			}
			function pulse(){
			  const el = findTarget(); if(!el) return;
			  const r = el.getBoundingClientRect();
			  const msg = { xpraWindowSize: { w: Math.round(r.width), h: Math.round(r.height) } };
			  try { parent.postMessage(msg, location.origin); } catch(e) {}
			}
			new MutationObserver(pulse).observe(document.documentElement,{subtree:true,childList:true,attributes:true});
			addEventListener("resize",pulse);
			setInterval(pulse,500);
			// First attempt shortly after load
			setTimeout(pulse,200);
		  })();
        </script></body>';

        # strip the /xpra-main/ prefix so Xpra’s absolute paths (/connect, /favicon.ico, etc) resolve
        rewrite ^/xpra-main/(.*)$ /\$1 break;
        # and rewrite any absolute redirect back under /xpra-main/ for the browser
        proxy_redirect ~^(/.*)$ /xpra-main\$1;
        proxy_pass http://127.0.0.1:14500;
    }
	
    # Xpra MAIN absolute-path assets (no auth gate)
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
	
    # TEMP: Xpra WebSocket for MAIN (absolute /connect used by the HTML5 client)
    location = /connect {
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
    server_name $DOMAIN _;

    # convenience redirects without trailing slash
    location = /xpra-main { return 301 /xpra-main/; }

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

    # XPRA HTML5 MAIN (no auth gate; iframe+WS)
    location /xpra-main/ {
        auth_request off;
        # Viewer toggle (0=hidden => 404; 1=visible)
        set \$xpra_main_enabled 0;
        include /opt/tradingbot/runtime/xpra_main_enabled.conf;
        if (\$xpra_main_enabled = 0) {
            return 404;
        }
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

        # allow HTML rewrite + strip meta CSP
        proxy_set_header Accept-Encoding "";
        sub_filter_types text/html;
        sub_filter_once off;
        sub_filter '<meta http-equiv="Content-Security-Policy"' '<meta http-equiv="x-removed-CSP">';

        # hide Xpra chrome, transparent background
        sub_filter '</head>' '<style id="xpra-embed">
          #toolbar,#menubar,#footer,#taskbar,#sidepanel,#notifications{display:none!important}
          html,body,#workspace{margin:0;padding:0;width:100%;height:100%;background:transparent}
          .window{box-shadow:none!important;border:none!important}
        </style></head>';

        # emit size of first app window (or canvas) to parent, ensure native pixels (no scaling)
        sub_filter '</body>' '<script>
		  (function(){
			try{ if(!/scaling=/.test(location.search)) history.replaceState(null,"",location.pathname+"?scaling=off"); }catch(e){}
			function findTarget(){
			  // Xpra v17: windows are ".window"; before that, at least a #screen canvas exists
			  return document.querySelector(".window") || document.querySelector("#screen canvas");
			}
			function pulse(){
			  const el = findTarget(); if(!el) return;
			  const r = el.getBoundingClientRect();
			  const msg = { xpraWindowSize: { w: Math.round(r.width), h: Math.round(r.height) } };
			  try { parent.postMessage(msg, location.origin); } catch(e) {}
			}
			new MutationObserver(pulse).observe(document.documentElement,{subtree:true,childList:true,attributes:true});
			addEventListener("resize",pulse);
			setInterval(pulse,500);
			// First attempt shortly after load
			setTimeout(pulse,200);
		  })();
		    </script></body>';

        # strip the /xpra-main/ prefix so Xpra’s absolute paths (/connect, /favicon.ico, etc) resolve
        rewrite ^/xpra-main/(.*)$ /\$1 break;
        # and rewrite any absolute redirect back under /xpra-main/ for the browser
        proxy_redirect ~^(/.*)$ /xpra-main\$1;
        proxy_pass http://127.0.0.1:14500;
    }

    # Xpra MAIN absolute-path assets (no auth gate)
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

    # TEMP: Xpra WebSocket for MAIN (absolute /connect used by the HTML5 client)
    location = /connect {
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

echo "[DAEMONS] Restarting TradingBot services so changes take effect..."
systemctl daemon-reexec || true
systemctl restart uvicorn.service || true
systemctl restart xpra-ibgateway-main.service || true
systemctl reload nginx || true

echo "[DAEMONS] All core services restarted."

echo "---------------------------------------------"
if [[ $NO_TLS -eq 1 ]]; then
  echo "Install complete (DEV, HTTP). Open:  http://$DOMAIN"
else
  echo "Install complete (PROD, HTTPS). Open: https://$DOMAIN"
fi

