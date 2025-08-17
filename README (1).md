
# TradingBot Secure Setup (VPS, Debian 13)

This bundle contains:
- `app/auth.py` — FastAPI router for first-time password setup, TOTP enrollment (QR), login, session cookie, `GET /auth/validate` for Nginx `auth_request`.
- `deploy/ibkr/run-ibgateway.sh` — Starts Xvfb + Openbox + x11vnc + websockify + IB Gateway.
- `deploy/systemd/*.service` — Units for `ibgateway`, `websockify`, `uvicorn` (optional if you use your watchdog).
- `deploy/nginx/tradingbot.conf` — Reverse-proxy with single sign-on for both the Flutter UI and the noVNC console.
- `flutter_snippets/settings_ibkr_embed.dart` — Flutter widget to host the noVNC client inside your Settings page.

## Quick Steps

1. **Packages**
```bash
sudo apt update
sudo apt install -y python3-fastapi python3-uvicorn python3-passlib python3-pyotp python3-qrcode   xvfb openbox x11vnc novnc websockify nginx certbot python3-certbot-nginx   libgtk-3-0 libglib2.0-0 libpango-1.0-0 libcairo2 libgdk-pixbuf-2.0-0   libxcomposite1 libxdamage1 libxfixes3 libxss1 libxtst6 libxi6 libxrandr2 libnss3   libasound2 libatk1.0-0 libatk-bridge2.0-0 libcups2 libx11-xcb1 libxcb1 libxcb-render0 libxcb-shm0 libdrm2 libgbm1 libfontconfig1 fonts-dejavu-core
```

2. **Install IB Gateway**
```bash
sudo useradd -m -s /bin/bash ibkr || true
sudo mkdir -p /opt/ibkr && sudo cp /mnt/data/deploy/ibkr/run-ibgateway.sh /opt/ibkr/ && sudo chown -R ibkr:ibkr /opt/ibkr
# Download a gateway build (example 1037 shown—adjust as needed)
sudo -u ibkr bash -lc 'mkdir -p ~/Downloads && curl -fL -o ~/Downloads/ibgateway.sh https://download2.interactivebrokers.com/installers/ibgateway/latest-standalone/ibgateway-latest-standalone-linux-x64.sh && chmod +x ~/Downloads/ibgateway.sh && ~/Downloads/ibgateway.sh -q -dir $HOME/Jts/ibgateway/1037'
```

3. **Systemd**
```bash
sudo cp /mnt/data/deploy/systemd/ibgateway.service /etc/systemd/system/
sudo cp /mnt/data/deploy/systemd/uvicorn.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now ibgateway
sudo systemctl enable --now uvicorn
```

4. **Nginx + TLS**
```bash
sudo cp /mnt/data/deploy/nginx/tradingbot.conf /etc/nginx/sites-available/tradingbot
sudo ln -sf /etc/nginx/sites-available/tradingbot /etc/nginx/sites-enabled/tradingbot
sudo nginx -t && sudo systemctl reload nginx
# Issue a cert with your domain:
sudo certbot --nginx -d your.domain
```

5. **First-time setup**
- Open `https://your.domain/`.
- If not initialized, the backend returns `stage: init`. Your Flutter UI should show a simple flow:
  1) Set a **new password**.
  2) **Scan QR** shown from `GET /auth/enroll_qr` with Google Authenticator.
  3) Enter the 6-digit **TOTP**.
  4) Login; session cookie is issued. Nginx `auth_request` gates all routes, including `/websockify`.

6. **Embed IBKR console in Flutter**
- Add the widget from `flutter_snippets/settings_ibkr_embed.dart` to your Settings page. It opens `/vnc.html?...&path=websockify` which is served by noVNC and proxied through Nginx with the same auth gate.

7. **Wire controls**
- Your Flutter page can call `POST /system/control` to restart modules (engine, ibgateway, etc.) if you extend your watchdog to manage IBKR.
