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
2. **Nessie**: set `NESSIE_API_KEY`. Optionally seed the offline demo household:
   `.venv/bin/python -m app.demo.seed`.
3. **Photon**: set `PHOTON_API_KEY`, `PHOTON_PROJECT_ID`, `PHOTON_AGENT_HANDLE`. The key needs
   `project:read`, `project:write`, and **`platforms:read` + `platforms:write`** so sign-up can
   assign lines.
4. Start the server and open **`/signup`**. Each person enters their name and iPhone number.

### Sign-up (`/signup`)

Signing up with a phone number:
- creates that person's household: their own synthetic Nessie customer with Everyday Checking
  ($1,850) and Grocery Fund ($120), plus two weeks of backdated purchases in DEMO_MODE;
- asks Photon to assign a shared iMessage line to **that phone number**
  (`POST /v1/projects/{id}/platforms/imessage/assignments`), which uses one seat on the Photon plan;
- shows the number to text. Shared lines can't send the first message, so the person texts "hi"
  and gets the welcome.

Signing up again with the same number returns the same household and line. If Photon can't
assign a line (missing permission, no seats), the page says why and falls back to
`PHOTON_AGENT_HANDLE`, which works if that number was added by hand in the Photon dashboard.
Anyone who texts without signing up joins the demo household (DEMO_MODE) or gets their own.

The startup log says which side is live and which is SIMULATED; so does `/health`.

### What live Nessie actually does

Checked against `prod-api.nessieisreal.com` with a real key:
- **Whole dollars only:** amounts and balances drop the cents ($42.18 is stored as $42). The
  app keeps exact grocery totals from the itemized description and offers sweeps in whole dollars.
- **Balances never change on their own:** purchases, transfers and deposits are stored as
  records, and `PUT` can't set a balance. The app shows a running balance computed from Nessie's
  records: opening balance − purchases − transfers out + deposits in.
- **Transfers have no destination field**, so a sweep is recorded as a transfer out of Everyday
  Checking plus a matching deposit into Grocery Fund.
- Merchant `category` is a single string, and empty lists come back as 404.

## Shared fridge with the iPhone app (SpacetimeDB)

Set `SPACETIME_HOST` and `SPACETIME_DB` (already filled in `.env.example`) and the backend's fridge and
the app's fridge become one. Code: [`app/spacetime/`](app/spacetime/bridge.py).

- Each backend household signs in to SpacetimeDB with its own identity and creates an app household
  on first sync. Members get its 6-character invite code in their welcome text (or reply **APP**) and
  enter it in the app's **Join** field.
- To use a household that already exists in the app, text **LINK <code>** with that household's code
  (in the app under Settings → Household). The app's **Connect your bank** does the same thing:
  `POST /signup` with `app_invite_code` joins the new (or existing) bank household straight to that
  app household, and `GET /demo/state?app_household_id=…` returns the bank linked to it.
- Bank items sent to the app carry `price` (per unit) and `store` (the merchant), with
  `addedBy: "bank-purchase"` so the app can mark them.
- Every 3 s (15 s outside DEMO_MODE) the bridge syncs both ways. Bank purchases appear in the app;
  items added in the app show up in FRIDGE, EXPIRING and nudges; USED / TOSSED here and −1 / delete in
  the app update the other side.
- The backend keeps one row per unit (needed for waste and sweeps) and the app one row per product with
  a count. Sync is a three-way merge against the last agreed counts, so simultaneous edits on both
  sides add up instead of overwriting each other. After an item exists, only counts flow from here to
  the app; a printed expiry date set in the app updates the backend's units.
- Removing an already-expired item in the app counts as tossed (its waste was recorded when it
  expired). Items added in the app have no price, so they count $0 toward waste.
- `/health` and the startup log show `spacetime: live | mock`. Without the two settings the sync runs
  against an in-memory mock.

## Demo controls (`DEMO_MODE=true`)

| Page button / endpoint | CLI | What it does |
|---|---|---|
| Household picker · `?household_id=` on buy/sweep/state | | Defaults to the newest sign-up |
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

`START` · `APP` (app invite code) · `LINK <code>` · `FRIDGE` · `EXPIRING` · `USED <item>` / "finished the milk" · `TOSSED <item>` ·
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
`photonhq-api` client uses); it hasn't been run against a live Photon key yet. The Nessie client
was checked against the live API (see above). Each API sits behind one small client class, so a
mismatch is fixed in one place.
