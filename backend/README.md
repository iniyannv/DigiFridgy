# DigiFridgey backend (Nessie + Photon)

Your bank already sees your grocery purchases, so let it stock your fridge. This service turns
grocery transactions from Capital One's **Nessie** API into a live fridge inventory, then texts
(and talks) with you over iMessage through **Photon 2.0**: what's expiring, what to buy, and how
much food money you're wasting. Money only moves after you reply YES.

All customers, merchants and purchases are **synthetic** (created in Nessie). Merchant names are
fictional. No real bank data.

## Quick start (offline, no keys)

```bash
cd backend
python3.12 -m venv .venv && .venv/bin/pip install -r requirements.txt
.venv/bin/uvicorn app.main:app --port 8000
```

Open http://127.0.0.1:8000/demo. With no keys, Nessie and Photon run as **SIMULATED** mocks:
the page has a chat box that plays the part of your phone. Text "hi", press **Buy**, and the
fridge texts you back.

Run the tests:

```bash
cd backend && .venv/bin/python -m pytest -q
```

## Going live

1. `cp .env.example .env` and fill in what you have. Any missing key keeps that side mocked.
2. **Nessie**: set `NESSIE_API_KEY`. Seed the demo household (idempotent):
   `.venv/bin/python -m app.demo.seed`. It prints the customer and account IDs.
3. **Photon**: set `PHOTON_API_KEY`, `PHOTON_PROJECT_ID`, `PHOTON_AGENT_HANDLE`. In the Photon
   dashboard → iMessage, add the phone number **you will text from**, then assign a shared line.
   ⚠️ A shared line only accepts messages from the sender it was assigned for. Every person who
   should text the fridge (teammates, judges) needs their own assignment, or use a dedicated line.
4. Start the server and text the assigned number from that phone. The first message registers
   you and links you to the demo household.

The startup log says which side is live and which is SIMULATED; so does `/health`.

## Demo controls (`DEMO_MODE=true`)

| Page button / endpoint | CLI | What it does |
|---|---|---|
| Buy · `POST /demo/buy?basket=weekly` | `python -m app.demo.cli buy weekly` | Creates a real Nessie purchase at a fictional merchant; the fridge texts within seconds |
| +N days · `POST /demo/advance?days=3` | `cli advance 3` | Time-skip: items expire, nudges and waste fire |
| Budget sweep offer · `POST /demo/sweep` | `cli sweep` | Sends the "Move $X to Grocery Fund?" offer now |
| Reset demo · `POST /demo/reset` | `cli reset` | Clears local state, starts a fresh synthetic customer. `?wipe_nessie=true` also deletes Customers/Accounts/Purchases/Transfers **for the whole API key** |
| chat box · `POST /demo/mock/text` | `cli text "what's expiring?"` | SIMULATED inbound iMessage (mock Photon only) |

Baskets: `weekly` (Avon Fresh Market, 9 items, $42.18), `quick`, `taco`, `oat` (makes "milk"
ambiguous on purpose), `fuel` (non-grocery, ignored by the fridge).

Set `DEMO_TOKEN` if the server is reachable from the internet; the page then needs `?token=…`.

**Demo order tip:** run the budget sweep *before* a multi-day time-skip. A skip that crosses
Monday starts a new budget week, so "this week" spend resets to $0.

## Commands (always work, no LLM needed)

`START` · `FRIDGE` · `EXPIRING` · `USED <item>` / "finished the milk" · `TOSSED <item>` ·
`LIST` · `ADD <item>` · `REMOVE <item>` · `ADD ALL` · `MONEY` · `BUDGET 90` · `YES` / `NO` ·
`1`/`2` (pick between matches) · `DINNER` · "do I have eggs?" · `HELP` · `PRIVACY` · `STOP`

With `LLM_API_KEY` set, Gemini classifies messages the keyword rules don't recognize and writes
dinner ideas. It can never produce YES, NO, STOP or ADD ALL; those must be typed.

Human-in-the-loop moments: ambiguous item → "Which milk? 1) … 2) …"; a whole category → confirm;
any transfer → explicit YES (enforced by an atomic claim in `brain/pending.py`); one day before
expiry → "Still have it?"; running out of a staple → "add it to your list?".

## Voice (Photon number → ElevenLabs agent)

Follow Photon's voice quickstart (needs a voice-capable number; shared iMessage lines can't take
calls). In ElevenLabs, add **server tools** pointing at this backend (it must be publicly
reachable, e.g. through a tunnel). Every call needs header `X-Tool-Secret: $VOICE_TOOL_SECRET`.

| Tool | Request | Returns |
|---|---|---|
| fridge summary | `GET /voice/tools/fridge` | `{"text": "You have 12 items. Use soon: spinach tomorrow…"}` |
| check an item | `GET /voice/tools/check?item=eggs` | `{"text": "You have no eggs. Want me to add eggs to your list?", "have": 0}` |
| add to list | `POST /voice/tools/list/add` `{"item": "eggs"}` | `{"text": "Added eggs to your list. I also texted you."}` + an iMessage confirmation |

In DEMO_MODE the tools use the demo household; otherwise pass `handle=<caller's iMessage handle>`.

## Webhook (optional upgrade over polling)

Polling (`list_messages` every 2 s) is the default and needs no public URL. For webhooks, add a
destination in the Photon dashboard pointing at `https://<public-host>/photon/webhook` and set
`PHOTON_WEBHOOK_SECRET`. Signatures are verified with `standardwebhooks` against the raw body,
duplicates are dropped by `webhook-id`, and polling keeps running as the fallback (messages are
deduped by ID, so nobody gets two replies).

## How it fits together

```
app/
  main.py        FastAPI app + 3 loops: Photon poll (2 s), Nessie sync (5 s demo / 60 s), scheduler
  config.py      env settings; mocks switch on when a key is missing
  clock.py       the only "now"; demo time-skip is an offset stored in SQLite
  models.py      SQLite tables (households, members, items, list, waste, pending actions, …)
  households.py  provisions a synthetic Nessie customer + Everyday Checking + Grocery Fund
  nessie/        client.py (live + SIMULATED mock), sync.py (purchase → items → text), banking.py
  fridge/        parse.py (line items), shelf_life.json (~40 SKUs, approximate), inventory.py, matching.py
  photon/        client.py (REST + mock), inbound.py (guards, dedupe, poll), outbound.py, webhook.py
  brain/         router.py (keywords → intent), llm.py (Gemini, optional), commands.py, copy.py, pending.py
  scheduler/     jobs.py: expiry → waste ledger, day-before nudges, Sunday insight + sweep offer
  voice/         tools.py: endpoints for the ElevenLabs agent
  demo/          seed.py, baskets.json, routes.py, cli.py, static/demo.html
```

**Line items, honestly:** bank transactions don't carry line items. Here each synthetic grocery
purchase stores them in the Nessie `description` field
(`DIGIFRIDGEY_ITEMS v1 | milk_whole_1gal x1 3.49 | …`). In production this would come from
itemized merchant data shared with the bank.

**API notes.** Photon is called over its REST API (`https://api.photon.codes/v1/projects/{id}/messages`),
following the official OpenAPI contract and the iMessage quickstart (same fields the
`photonhq-api` client uses). Nessie paths and fields follow Nessie's official SDK. Both live in
one small client class each, so a mismatch found against the live API is fixed in one place.
The Nessie client has not yet been run against a live key: confirm account `balance` and
purchase `amount` types the first time you seed.
