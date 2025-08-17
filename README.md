
# Binance Spot Bot (MVP+) — Watchdog, Improved Web UI, PnL, File-based Control

**What's included**
- `base.py` watchdog (stdlib-only): starts **web**, **engine**, **telegram**; health checks; restarts; file-based commands; writes `runtime/status.json`.
- `app/web.py` FastAPI UI:
  - New plan form (no JSON text areas): dynamic add/remove **Entries** and **TPs**, **SL** fields
  - **Symbol search** (pulled from Binance), **balance slider** (% of BASE asset), **auto-refresh**, **price chart** (line, 1m klines)
  - Plans list with color-coded PnL, basic actions (Start/Cancel), and **Watchdog panel** (Start/Stop/Restart/Drain Engine, Restart Web/Telegram)
  - **/settings** page to set API key/secret & LIVE_TRADING (writes `.env` and asks watchdog to restart processes)
- `app/engine.py`:
  - Multi-entry / multi-TP / SL placing
  - Heartbeat (`engine.heartbeat`), **drain flag** (`runtime/engine.drain`)
  - Telegram notifier hooks (optional)
  - PnL metrics: avg entry, realized/unrealized, remaining qty, last price
- `app/binance_api.py`: spot wrapper + public market data, balances, klines, exchange info
- `app/notifier.py`: tiny Telegram sender (optional)
- SQLAlchemy models/repo; Pydantic schemas
- `.env.example`, `requirements.txt`

**Run**
```bash
python -m venv .venv
source .venv/bin/activate  # Windows: .venv\Scripts\activate
pip install -r requirements.txt
cp .env.example .env
python base.py
# UI: http://127.0.0.1:8000
```
Set API keys via **Settings** in the UI. Leave `LIVE_TRADING=false` until tested.
