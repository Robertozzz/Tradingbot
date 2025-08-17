
import asyncio, json
from telegram import Update
from telegram.ext import Application, CommandHandler, ContextTypes
from .config import TELEGRAM_BOT_TOKEN
from .repository import SessionLocal, init_db, create_plan
from .models import Plan, Entry, TakeProfit, StopLoss

async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    await update.message.reply_text("Hello! Send /newplan <json> to create a plan.")

async def newplan(update: Update, context: ContextTypes.DEFAULT_TYPE):
    try:
        data = json.loads(" ".join(context.args))
        plan = Plan(symbol=data["symbol"], side=data["side"], quote_amount=float(data["quote_amount"]))
        for e in data["entries"]:
            plan.entries.append(Entry(price=float(e["price"]), fraction=float(e["fraction"])))
        for t in data["take_profits"]:
            plan.take_profits.append(TakeProfit(price=float(t["price"]), fraction=float(t["fraction"])))
        if data.get("stop_loss"):
            sl = data["stop_loss"]
            plan.stop_loss = StopLoss(stop_price=float(sl["stop_price"]), limit_price=float(sl["limit_price"]))
        async with SessionLocal() as s:
            await create_plan(s, plan)
        await update.message.reply_text(f"Plan {plan.id} created.")
    except Exception as e:
        await update.message.reply_text(f"Error: {e}")

async def main():
    await init_db()
    app = Application.builder().token(TELEGRAM_BOT_TOKEN).build()
    app.add_handler(CommandHandler("start", start))
    app.add_handler(CommandHandler("newplan", newplan))
    await app.run_polling()

if __name__ == "__main__":
    asyncio.run(main())
