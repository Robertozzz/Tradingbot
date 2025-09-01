"""
gpt5_tool_runner.py

A minimal, production-friendly skeleton that:
- Exposes "tools" (web_search, fetch_url, quote) to GPT-5 via the Responses API
- Lets GPT-5 decide when to call those tools for live research
- Supports both "expert analysis" and "JSON trade instruction" use cases
- Streams output, collects usage, and (optionally) computes cost

Requirements:
  pip install --upgrade openai requests beautifulsoup4

Environment:
  export OPENAI_API_KEY=sk-...
  export SEARCH_API_KEY=...         # if you use a web search API
"""

from __future__ import annotations
import os, json, time, typing as T
from dataclasses import dataclass
import requests
from bs4 import BeautifulSoup
from openai import OpenAI

# =========================
# Config
# =========================
OPENAI_MODEL = os.environ.get("OPENAI_MODEL", "gpt-5")  # or "gpt-5-mini"
ENABLE_STREAMING = True

# OPTIONAL: If you want to compute cost yourself, set prices here (per 1M tokens).
# Keep these in a config so you can update them centrally if pricing changes.
GPT5_INPUT_PER_M = 1.25      # USD per 1M input tokens  (example)
GPT5_OUTPUT_PER_M = 10.00    # USD per 1M output tokens (example)

# ---- Bing Search config ----
# You can change endpoints if Azure tenant uses a different base URL.
BING_BASE = os.getenv("BING_BASE", "https://api.bing.microsoft.com")
BING_WEB_ENDPOINT  = f"{BING_BASE}/v7.0/search"
BING_NEWS_ENDPOINT = f"{BING_BASE}/v7.0/news/search"
SEARCH_API_KEY = os.getenv("SEARCH_API_KEY", "")   # set via Settings UI

# =========================
# Simple tool backends
# =========================
def tool_web_search(
    query: str,
    count: int = 5,
    mode: str = "news",              # "news" or "web"
    mkt: str = "en-US",              # market (e.g., "en-US", "nl-NL")
    freshness: str | None = None,    # e.g., "Day", "Week", "Month"
    sites: list[str] | None = None,  # optional allowlist of domains
) -> T.Dict[str, T.Any]:
    """
    Bing-backed search tool.
    - mode="news": Bing News Search
    - mode="web":  Bing Web Search
    Returns normalized [{title, url, snippet, date}] items.
    """
    if not SEARCH_API_KEY:
        return {"provider": "bing", "results": [], "note": "SEARCH_API_KEY not set"}

    headers = {"Ocp-Apim-Subscription-Key": SEARCH_API_KEY}
    params: dict[str, T.Any] = {
        "q": query,
        "count": max(1, min(count, 10)),
        "mkt": mkt,
    }
    if freshness:
        params["freshness"] = freshness  # Day|Week|Month

    # Domain allowlist (if supplied)
    if sites:
        # Bing syntax supports (site:foo.com OR site:bar.com)
        site_expr = " OR ".join([f"site:{s}" for s in sites if s])
        if site_expr:
            params["q"] = f"({params['q']}) ({site_expr})"

    endpoint = BING_NEWS_ENDPOINT if mode == "news" else BING_WEB_ENDPOINT
    r = requests.get(endpoint, headers=headers, params=params, timeout=25)
    r.raise_for_status()
    data = r.json()

    results: list[dict] = []
    if mode == "news":
        for item in (data.get("value") or [])[:params["count"]]:
            # Prefer originalUrl if available
            url = item.get("url") or item.get("webSearchUrl")
            name = item.get("name") or ""
            snippet = item.get("description") or ""
            date = item.get("datePublished")
            results.append({"title": name, "url": url, "snippet": snippet, "date": date})
    else:
        for item in (data.get("webPages", {}).get("value") or [])[:params["count"]]:
            name = item.get("name") or ""
            url = item.get("url")
            snippet = item.get("snippet") or ""
            date = item.get("dateLastCrawled")
            results.append({"title": name, "url": url, "snippet": snippet, "date": date})

    return {"provider": "bing", "mode": mode, "results": results, "mkt": mkt, "freshness": freshness}

def tool_fetch_url(url: str, max_chars: int = 20000) -> T.Dict[str, T.Any]:
    """
    Fetch a URL and return plain text (very simple reader).
    In production, consider trafilatura / newspaper3k / Mercury / Readability server.
    """
    try:
        r = requests.get(url, timeout=25, headers={"User-Agent": "Mozilla/5.0"})
        r.raise_for_status()
        soup = BeautifulSoup(r.text, "html.parser")

        # Drop script/style
        for bad in soup(["script", "style", "noscript"]): bad.decompose()
        text = " ".join(soup.get_text(" ", strip=True).split())
        if len(text) > max_chars:
            text = text[:max_chars] + " …[truncated]"

        title = soup.title.string.strip() if soup.title and soup.title.string else ""
        return {"ok": True, "title": title, "url": url, "text": text}
    except Exception as e:
        return {"ok": False, "url": url, "error": str(e)}


def tool_quote(symbol: str) -> T.Dict[str, T.Any]:
    """
    Placeholder market data fetch. Replace with your real source (IBKR, Yahoo Finance, Polygon, etc.)
    """
    # Example static response for wiring; replace with live data.
    dummy = {
        "symbol": symbol.upper(),
        "price": 11.78,
        "currency": "EUR",
        "as_of": int(time.time())
    }
    return {"ok": True, "data": dummy}


# =========================
# OpenAI client & schemas
# =========================
# Client is created lazily after applying runtime settings
def _mk_client() -> OpenAI:
    api_key = os.environ.get("OPENAI_API_KEY", "")
    if not api_key:
        raise RuntimeError("OPENAI_API_KEY not set")
    return OpenAI(api_key=api_key)

client = None  # will be set in apply_runtime_settings()

def _settings_path() -> str:
    # Keep in sync with web._openai_settings_path()
    for p in [
        Path(__file__).resolve().parent.parent / "runtime" / "openai_settings.json",
        Path.cwd() / "runtime" / "openai_settings.json",
    ]:
        if p.exists():
            return str(p)
    return str(Path.cwd() / "runtime" / "openai_settings.json")

def apply_runtime_settings():
    """Load runtime/openai_settings.json and push into env + globals."""
    global OPENAI_MODEL, client, SEARCH_API_KEY
    try:
        fp = Path(_settings_path())
        if fp.exists():
            data = json.loads(fp.read_text(encoding="utf-8"))
            if "openai_api_key" in data:
                os.environ["OPENAI_API_KEY"] = (data.get("openai_api_key") or "").strip()
            if "search_api_key" in data:
                os.environ["SEARCH_API_KEY"] = (data.get("search_api_key") or "").strip()
                SEARCH_API_KEY = os.environ.get("SEARCH_API_KEY", "")
            if "model" in data:
                OPENAI_MODEL = (data.get("model") or "gpt-5").strip()
            if "enable_browsing" in data:
                os.environ["OPENAI_ENABLE_BROWSING"] = "1" if data.get("enable_browsing") else "0"
    except Exception:
        pass
    # (re)create client with current key
    globals()["client"] = _mk_client()

TOOLS: list[dict] = [
    {
        "name": "web_search",
        "description": "Search the web/news via Bing. mode=news|web; optional freshness=Day|Week|Month; mkt=en-US|nl-NL; sites=[domains].",
        "input_schema": {
            "type": "object",
            "properties": {
                "query": {"type": "string"},
                "count": {"type": "integer", "minimum": 1, "maximum": 10},
                "mode": {"type": "string", "enum": ["news", "web"]},
                "mkt": {"type": "string"},
                "freshness": {"type": "string"},
                "sites": {"type": "array", "items": {"type": "string"}}
            },
            "required": ["query"]
        }
    },
    {
        "name": "fetch_url",
        "description": "Fetch and extract readable text from a URL.",
        "input_schema": {
            "type": "object",
            "properties": {
                "url": {"type": "string"},
                "max_chars": {"type": "integer", "minimum": 1000, "maximum": 100000}
            },
            "required": ["url"]
        }
    },
    {
        "name": "quote",
        "description": "Get latest indicative quote for a ticker symbol.",
        "input_schema": {
            "type": "object",
            "properties": {
                "symbol": {"type": "string"}
            },
            "required": ["symbol"]
        }
    }
]

SYSTEM_ANALYST = """\
You are an equity research analyst.
- If information may be outdated, decide whether to use the available tools (web_search, fetch_url, quote).
- When you use web_search, pick 3–6 good sources, then fetch 1–3 URLs for details.
- Synthesize a balanced, current analysis: business, recent results, valuation, catalysts, risks.
- Provide a clear BUY/HOLD/SELL view with rationale and time horizon.
- Cite sources inline as [title](url).
- Keep answers concise but decision-useful.
"""

SYSTEM_TRADER = """\
You are a trading decision engine.
- Use tools when necessary (web_search, fetch_url, quote).
- Return ONLY JSON matching the provided schema, no extra text.
- Prefer conservative sizing if uncertainty is high.
- Include a brief natural-language rationale and confidence (0.0–1.0).
"""

# Strict JSON schema for trade instructions
TRADE_JSON_SCHEMA = {
    "name": "trade_instruction",
    "schema": {
        "type": "object",
        "properties": {
            "symbol": {"type": "string"},
            "action": {"type": "string", "enum": ["BUY", "SELL", "HOLD", "FLAT"]},
            "order_type": {"type": "string", "enum": ["MARKET", "LIMIT"]},
            "quantity": {"type": "number", "minimum": 0},
            "limit_price": {"type": ["number", "null"]},
            "time_horizon_days": {"type": "integer", "minimum": 0},
            "rationale": {"type": "string"},
            "confidence": {"type": "number", "minimum": 0, "maximum": 1}
        },
        "required": ["symbol", "action", "order_type", "quantity", "limit_price",
                     "time_horizon_days", "rationale", "confidence"],
        "additionalProperties": False
    }
}


# =========================
# Tool dispatch
# =========================
def call_tool(name: str, arguments: dict) -> dict:
    if name == "web_search":
        return tool_web_search(
            arguments["query"],
            arguments.get("count", 5),
            arguments.get("mode", "news"),
            arguments.get("mkt", "en-US"),
            arguments.get("freshness"),
            arguments.get("sites"),
        )
    if name == "fetch_url":
        return tool_fetch_url(arguments["url"], arguments.get("max_chars", 20000))
    if name == "quote":
        return tool_quote(arguments["symbol"])
    return {"error": f"Unknown tool: {name}"}


# =========================
# Core runner (single-turn with tool loop)
# =========================
@dataclass
class RunResult:
    text: str
    usage: dict
    tool_calls: list[dict]
    final: dict | None  # if JSON response_format used


def run_with_tools(system: str, user_input: str,
                   force_json_schema: dict | None = None) -> RunResult:
    """
    Send a request to GPT-5 with tool definitions. Resolve any tool calls,
    then return the final message. If force_json_schema is provided,
    we ask the model to return strict JSON conforming to that schema.
    """
    tool_calls_all: list[dict] = []
    messages: list[dict] = [{"role": "system", "content": system},
                            {"role": "user", "content": user_input}]

    response_format = None
    if force_json_schema:
        response_format = {
            "type": "json_schema",
            "json_schema": {
                "name": force_json_schema["name"],
                "schema": force_json_schema["schema"],
                "strict": True
            }
        }

    while True:
        if client is None:
            apply_runtime_settings()
        # Create response
        resp = client.responses.create(
            model=OPENAI_MODEL,
            input=messages,
            tools=TOOLS,
            response_format=response_format,
            stream=ENABLE_STREAMING
        )

        # Handle streaming or non-streaming uniformly
        final_text = ""
        final_json: dict | None = None
        tool_request = None

        if ENABLE_STREAMING:
            # Stream chunks; detect tool calls and the final message
            for event in resp:
                if event.type == "response.output_text.delta":
                    final_text += event.delta
                elif event.type == "response.function_call.arguments.delta":
                    # Tool call in progress; accumulate (OpenAI emits name & args)
                    tool_request = tool_request or {"name": None, "arguments": ""}
                    if hasattr(event, "name") and event.name:
                        tool_request["name"] = event.name
                    tool_request["arguments"] += event.delta
                elif event.type == "response.function_call.completed":
                    # Completed call; we'll execute below
                    pass
                elif event.type == "response.output_text.done":
                    pass
                elif event.type == "response.completed":
                    pass
            # After stream ends, grab usage from the "resp" once finished
            usage = getattr(resp, "usage", None) or {}
        else:
            # Non-streaming path
            final_text = resp.output_text or ""
            usage = resp.usage or {}
            # If tool call present (non-streaming), pick it up from resp
            if resp.tool:
                tool_request = {
                    "name": resp.tool.name,
                    "arguments": json.dumps(resp.tool.arguments or {})
                }

        # If the model asked for a tool, execute it and loop
        if tool_request and tool_request.get("name"):
            try:
                args = json.loads(tool_request["arguments"] or "{}")
            except Exception:
                args = {}
            name = tool_request["name"]
            tool_calls_all.append({"name": name, "arguments": args})
            tool_result = call_tool(name, args)

            # Append tool result and continue the loop
            messages.append({"role": "assistant",
                             "content": "",
                             "tool_calls": [{"name": name, "arguments": args}]})
            messages.append({"role": "tool",
                             "name": name,
                             "content": json.dumps(tool_result)})
            # Reset format: if we forced JSON (trade), keep forcing it until final
            continue

        # No tool call -> final answer
        if response_format and final_text.strip():
            # When strict JSON was requested, the "text" will be the JSON
            try:
                final_json = json.loads(final_text)
            except Exception:
                # If parsing fails, you can re-ask the model with a short repair prompt
                pass

        return RunResult(text=final_text, usage=usage, tool_calls=tool_calls_all, final=final_json)


# =========================
# Examples
# =========================
if __name__ == "__main__":
    apply_runtime_settings()
    # 1) Expert current analysis (model decides if/what to fetch)
    user_prompt_analysis = (
        "Give me an up-to-date expert analysis of Fugro (Euronext: FUR). "
        "Include recent results, valuation context, catalysts, risks, and a BUY/HOLD/SELL call."
    )
    res1 = run_with_tools(SYSTEM_ANALYST, user_prompt_analysis)
    print("\n=== ANALYSIS ===")
    print(res1.text)
    print("\nTool calls:", res1.tool_calls)
    print("Usage:", res1.usage)

    # Optional rough cost calc if usage is present and you’ve set pricing above
    if res1.usage:
        in_tokens = res1.usage.get("input_tokens", 0)
        out_tokens = res1.usage.get("output_tokens", 0)
        cost = (in_tokens / 1_000_000) * GPT5_INPUT_PER_M + (out_tokens / 1_000_000) * GPT5_OUTPUT_PER_M
        print(f"~Estimated cost: ${cost:.5f}")

    # 2) JSON trade instruction (strict schema)
    user_prompt_trade = (
        "Based on the latest information, decide whether to place a trade in FUR.AS. "
        "Use tools if necessary, then output ONLY the JSON trade object."
    )
    res2 = run_with_tools(SYSTEM_TRADER, user_prompt_trade, force_json_schema=TRADE_JSON_SCHEMA)
    print("\n=== TRADE JSON ===")
    print(res2.text)       # JSON string
    print("\nParsed JSON:", res2.final)
    print("Tool calls:", res2.tool_calls)
    print("Usage:", res2.usage)

# ---------- tiny test entry ----------
def test_openai(prompt: str = "ping") -> tuple[str, dict]:
    """Small, cheap test to validate key/model from /api/openai/test."""
    apply_runtime_settings()
    r = _mk_client().responses.create(
        model=OPENAI_MODEL,
        input=f"Reply exactly 'pong' if you see '{prompt}'. Otherwise say 'nope'."
    )
    return (r.output_text or ""), (r.usage or {})