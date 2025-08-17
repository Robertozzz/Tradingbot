
Wired UI + API + Engine loop (snapshots)

Run:
  python -m app.engine
  uvicorn app.web:app --host 0.0.0.0 --port 8080

Web UI:
- Dashboard: KPIs + 24h change, wealth range (1D/1W/1M), allocation doughnut
- Assets: table with 24h color and mini sparklines
- Accounts: cards + account allocation doughnut + portfolio line
- Trades: reads /exports (or /runtime) trades_open/closed.json
- Live updates: /api/metrics/stream (SSE), fallback polling every 15s

Engine:
- Gentle loop (~10s) writing exports/accounts.json, exports/assets.json (fallback from runtime/assets.json)
- Writes rolling snapshots to exports/history/assets-YYYYMMDD-HHMMSS.json
