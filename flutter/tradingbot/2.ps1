# Fail fast
$ErrorActionPreference = 'Stop'

# 3) Commit & push
Set-Location 'D:\Tradingbot'   # (check the exact casing of this path)
git add .
git commit -m "Bugfixes"
git push -u origin main

# 4) Back to Flutter dir (optional)
Set-Location 'D:\Flutter\tradingbot'
