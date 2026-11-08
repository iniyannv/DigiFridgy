"""Create or update the DigiFridgy ElevenLabs voice agent and its five server tools.

    .venv/bin/python -m app.voice.setup_agent                 # uses PUBLIC_URL, else a running quick tunnel
    .venv/bin/python -m app.voice.setup_agent https://x.trycloudflare.com

Needs ELEVENLABS_API_KEY and VOICE_TOOL_SECRET in backend/.env. Safe to re-run: tools and the agent
are matched by name and updated in place, so a new tunnel address only needs one more run. The phone
number (Photon SIP -> ElevenLabs) is imported and assigned to this agent in the ElevenLabs dashboard.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path

import httpx

API = "https://api.elevenlabs.io"
AGENT_NAME = "DigiFridgy"
# The caller's number goes in a header: as a query parameter, an empty system__caller_id (browser tests)
# makes ElevenLabs fail the tool before calling us.
CALLER_HEADER = {"variable_name": "system__caller_id"}

FIRST_MESSAGE = "Hi! It's DigiFridgy, your fridge helper. What do you need?"
PROMPT = """You are DigiFridgy, a friendly fridge assistant on a phone call with someone in the household.
You help them check what's in their fridge, what's about to expire, what to cook, and add things to the
shopping list.

How to talk:
- Answer in one or two short, natural sentences. This is a phone call: no lists, no emoji, no markdown.
- Always use the tools for anything about their fridge, shopping list or recipes. Never guess food,
  amounts or dates; say only what the tools return.
- After a tool answers, pass its answer on in your own words and offer one useful next step
  (for example: after what's expiring, offer recipe ideas; after "you have no eggs", offer to add eggs).
- If they ask to add something, add it right away and confirm.
- Money: you can't move money, change budgets or settle up on a call. Tell them to text the
  DigiFridgy number instead; money only moves with a typed YES in their own chat.
- If a tool fails, say you couldn't reach their fridge right now and suggest texting the same number.
"""


def tools(base: str, secret: str) -> list[dict]:
    headers = {"X-Tool-Secret": secret, "X-Caller-Id": CALLER_HEADER}

    def get(name, path, description, query=None):
        schema = {"url": f"{base}/voice/tools/{path}", "method": "GET", "request_headers": headers}
        if query:
            schema["query_params_schema"] = {"properties": query, "required": []}
        return {"type": "webhook", "name": name, "description": description, "response_timeout_secs": 15,
                "api_schema": schema}

    return [
        get("fridge_summary", "fridge",
            "Everything in the caller's fridge, with what to use soon. Use when they ask what they have."),
        get("check_item", "check",
            "Whether the caller has a specific food in the fridge and when to use it.",
            {"item": {"type": "string", "description": "The food to check, e.g. 'eggs' or 'whole milk'."}}),
        get("whats_expiring", "expiring",
            "Food in the caller's fridge that's about to expire. Use for 'what's going bad' or 'what should I use'."),
        get("recipe_ideas", "recipes",
            "Up to three recipe ideas. With no item, recipes that use what's about to expire; with an item, "
            "recipes with that ingredient. The full list is also texted to the caller.",
            {"item": {"type": "string",
                      "description": "Optional ingredient they want to cook with. Leave empty for 'use what's expiring'."}}),
        {"type": "webhook", "name": "add_to_list", "response_timeout_secs": 15,
         "description": "Adds a food to the household's shopping list and texts them a confirmation.",
         "api_schema": {"url": f"{base}/voice/tools/list/add", "method": "POST", "request_headers": headers,
                        "request_body_schema": {"type": "object", "required": ["item"], "properties": {
                            "item": {"type": "string", "description": "The food to add, e.g. 'milk'."}}}}},
    ]


def env() -> dict[str, str]:
    out = {}
    path = Path(__file__).resolve().parents[2] / ".env"
    for line in path.read_text().splitlines() if path.exists() else []:
        m = re.match(r"\s*([A-Z_]+)\s*=\s*(.*)", line)
        if m:
            out[m.group(1)] = m.group(2).split(" #")[0].strip().strip('"').strip("'")
    return {**out, **{k: v for k, v in os.environ.items() if k in ("ELEVENLABS_API_KEY", "VOICE_TOOL_SECRET")}}


def tunnel_url() -> str | None:
    """The address of a running `cloudflared tunnel --url` quick tunnel (from its local metrics port)."""
    try:
        pids = subprocess.run(["pgrep", "-f", "cloudflared tunnel.*--url"], capture_output=True, text=True).stdout.split()
    except FileNotFoundError:
        return None
    for pid in pids:
        lsof = subprocess.run(["lsof", "-a", "-p", pid, "-iTCP", "-sTCP:LISTEN", "-nP"], capture_output=True, text=True)
        for port in re.findall(r":(\d+) \(LISTEN\)", lsof.stdout):
            try:
                host = httpx.get(f"http://127.0.0.1:{port}/quicktunnel", timeout=3).json().get("hostname")
            except Exception:
                continue
            if host:
                return f"https://{host}"
    return None


def _all(http: httpx.Client, path: str, key: str) -> list[dict]:
    out, cursor = [], None
    while True:
        r = http.get(path, params={"page_size": 100, **({"cursor": cursor} if cursor else {})})
        r.raise_for_status()
        body = r.json()
        out += body.get(key, [])
        cursor = body.get("next_cursor")
        if not body.get("has_more") or not cursor:
            return out


def main() -> int:
    cfg = env()
    key, secret = cfg.get("ELEVENLABS_API_KEY", ""), cfg.get("VOICE_TOOL_SECRET", "")
    if not key:
        print("Set ELEVENLABS_API_KEY in backend/.env (ElevenLabs: Developers -> API Keys).")
        return 1
    if not secret:
        print("Set VOICE_TOOL_SECRET in backend/.env.")
        return 1
    base = (sys.argv[1] if len(sys.argv) > 1 else cfg.get("PUBLIC_URL") or tunnel_url() or "").rstrip("/")
    if not base.startswith("https://"):
        print("No public https address. Start: cloudflared tunnel --config /dev/null --url http://localhost:8001")
        return 1
    check = httpx.get(f"{base}/voice/tools/fridge", headers={"X-Tool-Secret": secret}, timeout=15)
    if check.status_code not in (200, 404):  # 404 = no household for an empty caller: still reachable
        print(f"{base} doesn't reach the voice tools (HTTP {check.status_code}). Is the server running?")
        return 1

    with httpx.Client(base_url=API, headers={"xi-api-key": key}, timeout=30) as http:
        existing = {t["tool_config"]["name"]: t["id"] for t in _all(http, "/v1/convai/tools", "tools")
                    if isinstance(t.get("tool_config"), dict)}
        ids = []
        for cfg_tool in tools(base, secret):
            name = cfg_tool["name"]
            if name in existing:
                r = http.patch(f"/v1/convai/tools/{existing[name]}", json={"tool_config": cfg_tool})
                verb = "updated"
            else:
                r = http.post("/v1/convai/tools", json={"tool_config": cfg_tool})
                verb = "created"
            if r.status_code >= 400:
                print(f"tool {name}: HTTP {r.status_code} {r.text[:500]}")
                return 1
            ids.append(r.json()["id"])
            print(f"tool {name}: {verb}")

        conversation = {"agent": {"first_message": FIRST_MESSAGE, "language": "en",
                                  "prompt": {"prompt": PROMPT, "llm": "gemini-2.5-flash", "tool_ids": ids}}}
        agents = [a for a in _all(http, "/v1/convai/agents", "agents") if a.get("name") == AGENT_NAME]
        if agents:
            agent_id = agents[0]["agent_id"]
            r = http.patch(f"/v1/convai/agents/{agent_id}", json={"name": AGENT_NAME, "conversation_config": conversation})
            verb = "updated"
        else:
            r = http.post("/v1/convai/agents/create", json={"name": AGENT_NAME, "conversation_config": conversation})
            verb = "created"
        if r.status_code >= 400:
            print(f"agent: HTTP {r.status_code} {r.text[:500]}")
            return 1
        agent_id = r.json().get("agent_id", agents[0]["agent_id"] if agents else "?")
        print(f"agent {AGENT_NAME}: {verb} ({agent_id})")
        print(f"tools point at {base}")
        print(f"open: https://elevenlabs.io/app/agents/agents/{agent_id}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
