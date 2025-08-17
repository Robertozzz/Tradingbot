
import os
from dotenv import load_dotenv

load_dotenv()

ENV = os.getenv("ENV", "dev")
LIVE_TRADING = os.getenv("LIVE_TRADING", "false").lower() == "true"
BASE_ASSET = os.getenv("BASE_ASSET", "USDT")

BINANCE_API_KEY = os.getenv("BINANCE_API_KEY", "")
BINANCE_API_SECRET = os.getenv("BINANCE_API_SECRET", "")

HOST = os.getenv("HOST", "0.0.0.0")
PORT = int(os.getenv("PORT", "8000"))

DATABASE_URL = os.getenv("DATABASE_URL", "sqlite+aiosqlite:///./bot.db")

TELEGRAM_BOT_TOKEN = os.getenv("TELEGRAM_BOT_TOKEN", "")
TELEGRAM_CHAT_ID = os.getenv("TELEGRAM_CHAT_ID", "")
