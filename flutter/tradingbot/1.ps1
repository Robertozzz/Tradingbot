cd "D:\tradingbot\Flutter\tradingbot"

# rebuild
flutter build web --release --wasm --base-href /

# Deployment directory
$dst = "D:\TradingBot\ui_build"

# Ensure deploy directory is clean
if (Test-Path $dst) {
    Get-ChildItem -Path $dst -Force | Remove-Item -Recurse -Force
} else {
    New-Item -ItemType Directory -Path $dst | Out-Null
}

# Copy new build
Copy-Item -Path "D:\TradingBot\flutter\tradingbot\build\web\*" -Destination $dst -Recurse -Force
Write-Host "Deployed to $dst" -ForegroundColor Green

# Git commit & push
cd "D:\Tradingbot"
git add .
git commit -m "No auth test"
git push -u origin main

# Return to Flutter project dir
cd "D:\tradingbot\Flutter\tradingbot"