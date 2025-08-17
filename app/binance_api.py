
from binance.spot import Spot
from .config import BINANCE_API_KEY, BINANCE_API_SECRET, LIVE_TRADING
import httpx

class BinanceAPI:
    def __init__(self):
        self.live = LIVE_TRADING and bool(BINANCE_API_KEY and BINANCE_API_SECRET)
        self.client = Spot(key=BINANCE_API_KEY, secret=BINANCE_API_SECRET) if self.live else None
        self.pub = Spot()
        self.http = httpx.Client(timeout=15.0)

    # ---- market data ----
    def get_price(self, symbol: str) -> float:
        data = self.pub.ticker_price(symbol)
        return float(data["price"])

    def get_exchange_info(self):
        return self.pub.exchange_info()

    def get_klines(self, symbol: str, interval: str="1m", limit: int=100):
        return self.pub.klines(symbol, interval, limit=limit)

    # ---- balances ----
    def get_balances(self):
        if not self.live:
            return {"balances": []}
        return self.client.account()

    # ---- orders (paper/live) ----
    def place_limit_buy(self, symbol: str, quantity: float, price: float):
        if not self.live:
            return {"orderId": f"paper-LMTBUY-{symbol}-{price}"}
        return self.client.new_order(symbol=symbol, side="BUY", type="LIMIT",
                                     timeInForce="GTC", quantity=self._fmt_qty(quantity), price=self._fmt_price(price))

    def place_market_buy(self, symbol: str, quote_amount: float):
        if not self.live:
            return {"orderId": f"paper-MKTBUY-{symbol}-{quote_amount}"}
        return self.client.new_order(symbol=symbol, side="BUY", type="MARKET",
                                     quoteOrderQty=self._fmt_price(quote_amount))

    def place_limit_sell(self, symbol: str, quantity: float, price: float):
        if not self.live:
            return {"orderId": f"paper-LMTSELL-{symbol}-{price}"}
        return self.client.new_order(symbol=symbol, side="SELL", type="LIMIT",
                                     timeInForce="GTC", quantity=self._fmt_qty(quantity), price=self._fmt_price(price))

    def place_stop_loss_limit_sell(self, symbol: str, quantity: float, stop_price: float, limit_price: float):
        if not self.live:
            return {"orderId": f"paper-SL-{symbol}-{stop_price}-{limit_price}"}
        return self.client.new_order(symbol=symbol, side="SELL", type="STOP_LOSS_LIMIT",
                                     timeInForce="GTC", quantity=self._fmt_qty(quantity),
                                     stopPrice=self._fmt_price(stop_price), price=self._fmt_price(limit_price))

    def get_order(self, symbol: str, order_id: str | int):
        if not self.live:
            return {"status": "FILLED"}
        return self.client.get_order(symbol=symbol, orderId=order_id)

    def _fmt_qty(self, x: float) -> str:
        return f"{x:.8f}".rstrip('0').rstrip('.')

    def _fmt_price(self, x: float) -> str:
        return f"{x:.8f}".rstrip('0').rstrip('.')


# ---- exchange filters cache ----
_filters = None
def _load_filters(self):
    if self._filters is None:
        info = self.get_exchange_info()
        m = {}
        for s in info.get("symbols", []):
            sym = s.get("symbol")
            f = {}
            for flt in s.get("filters", []):
                f[flt.get("filterType")] = flt
            m[sym] = f
        self._filters = m
    return self._filters

def _step_round(self, value: float, step: float) -> float:
    if step <= 0: return value
    # avoid float error; use integer division on scaled value
    scaled = int(value / step + 1e-12)
    return scaled * step

def _apply_filters(self, symbol: str, price: float|None, qty: float|None):
    flt = self._load_filters().get(symbol, {})
    if price is not None:
        pf = flt.get("PRICE_FILTER", {})
        tick = float(pf.get("tickSize", "0")) if pf else 0.0
        if tick:
            price = self._step_round(price, tick)
            # enforce bounds if present
            minp = float(pf.get("minPrice","0") or 0); maxp = float(pf.get("maxPrice","0") or 0)
            if minp and price < minp: price = minp
            if maxp and maxp>0 and price > maxp: price = maxp
    if qty is not None:
        lf = flt.get("LOT_SIZE", {})
        step = float(lf.get("stepSize", "0")) if lf else 0.0
        minq = float(lf.get("minQty","0") or 0); maxq = float(lf.get("maxQty","0") or 0)
        if step:
            qty = self._step_round(qty, step)
        if minq and qty < minq: qty = 0.0  # will fail min notional later
        if maxq and maxq>0 and qty > maxq: qty = maxq
    return price, qty

def _meets_min_notional(self, symbol: str, price: float, qty: float) -> bool:
    flt = self._load_filters().get(symbol, {})
    nf = flt.get("MIN_NOTIONAL", {})
    min_notional = float(nf.get("minNotional","0") or 0)
    return (price * qty) >= min_notional

def prepare_order(self, symbol: str, price: float|None, qty: float|None):
    p, q = self._apply_filters(symbol, price, qty)
    if p is not None and q is not None:
        if not self._meets_min_notional(symbol, p, q):
            # try bump qty minimally to meet min notional using step
            flt = self._load_filters().get(symbol, {})
            step = float(flt.get("LOT_SIZE",{}).get("stepSize","0") or 0)
            if step:
                need = max(0.0, (float(flt.get("MIN_NOTIONAL",{}).get("minNotional","0") or 0) / p) - q)
                steps = int(need/step + 0.9999)
                q = q + steps*step
            # final check
            if not self._meets_min_notional(symbol, p, q):
                raise ValueError("Order below MIN_NOTIONAL after rounding")
    return p, q
