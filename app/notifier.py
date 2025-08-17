
import os, http.client, urllib.parse

TG_TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN", "").strip()
TG_CHAT  = os.environ.get("TELEGRAM_CHAT_ID", "").strip()

def notify(text: str):
    if not (TG_TOKEN and TG_CHAT):
        return False
    try:
        conn = http.client.HTTPSConnection("api.telegram.org", timeout=5)
        path = f"/bot{TG_TOKEN}/sendMessage"
        payload = urllib.parse.urlencode({"chat_id": TG_CHAT, "text": text})
        headers = {"Content-Type": "application/x-www-form-urlencoded"}
        conn.request("POST", path, payload, headers)
        resp = conn.getresponse(); resp.read(); conn.close()
        return True
    except Exception:
        return False
