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
- The bridge syncs both ways as soon as something changes: it holds a WebSocket subscription to each
  linked household's `my_items` and `my_shopping` views, and every handled iMessage triggers a round too.
  A timer (3 s in DEMO_MODE, 15 s otherwise) is the fallback. Bank purchases appear in the app; items added
  in the app show up in FRIDGE, EXPIRING and nudges; USED / TOSSED here and −1 / delete in the app update
  the other side.
- **One shopping list.** LIST / ADD / REMOVE / ADD ALL over iMessage and the app's Shopping list are the
  same entries. Checking an entry off in the app takes it off the list here (unchecking puts it back),
  REMOVE here deletes it in the app, and the same item added on both sides becomes one entry. Staple
  suggestions ("ran out of milk, add it?") reach the app only once someone confirms them.
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

**Who can call what** ([`app/auth.py`](app/auth.py)):
- **Without `DEMO_TOKEN`**, `/demo/*` and `/signup` only answer requests from this computer (the simulator works). To use them from a phone or over a tunnel, set `DEMO_TOKEN` and the app's `DIGIFRIDGEY_TOKEN`. The token goes in the `X-Demo-Token` header, and the demo page passes `?token=…` along as that header.
- **The app's bank routes** (`state?app_household_id=`, `purchases`, `settle`, `settle/pay`, `settle/ask`, `roommate`) take *who you are* from `Authorization: Bearer <the app's SpacetimeDB token>`, which the server checks with SpacetimeDB.
  - You only see your own fridge's bank.
  - `settle/pay` always pays from your own checking, and never more than `quoted_amount` (the amount the dialog showed).
- **Operator actions** (the household picker, any conversation, `reset`) need this computer or `X-Admin-Token: $ADMIN_TOKEN` (`?admin=…` on the demo page). `reset?wipe_nessie=true` needs `ADMIN_TOKEN` to be set.
- **Signing up with a number that already has a bank** doesn't connect anything: it texts that phone, and it connects only after the owner replies YES.
- **Money moves exactly once:** each transfer is claimed in the database before Nessie is called ([`app/transfers.py`](app/transfers.py)). Nessie POSTs are never retried blindly, and a failed deposit is retried on its own by the scheduler.
- **YES only moves money as the full word YES**, from the person the offer was sent to. A money offer never replaces an open fridge question.
- **The demo clock** can't go back, and it is ignored outside `DEMO_MODE`.

**Demo order tip:** run the budget sweep *before* a multi-day time-skip. A skip that crosses
Monday starts a new budget week, so "this week" spend resets to $0.

## Commands (always work, no LLM needed)

`START` (the only way back after STOP) · `APP` (app invite code) · `LINK <code>` · `FRIDGE` · `EXPIRING` · `USED <item>` / "finished the milk" · `TOSSED <item>` ·
`LIST` · `ADD <item>` · `REMOVE <item>` · `ADD ALL` · `MONEY` · `BUDGET 90` · `TRIPS` · `SETTLE` · `YES` / `NO` ·
`1`/`2` (pick between matches, or drop a photo item) · "who's grabbing milk?" · `I WILL` · "I'll get eggs" · `DINNER` · "do I have eggs?" · `HELP` · `PRIVACY` · `STOP` (also CANCEL, STOPALL, UNSUBSCRIBE, REVOKE, OPT OUT, "stop texting me")

With `LLM_API_KEY` set, Gemini classifies messages the keyword rules don't recognize and writes
dinner ideas. It can never produce YES, NO, STOP or ADD ALL; those must be typed.

Human-in-the-loop moments: ambiguous item → "Which milk? 1) … 2) …"; a whole category → confirm;
any transfer → explicit YES (enforced by an atomic claim in `brain/pending.py`); one day before
expiry → "Still have it?"; running out of a staple → "add it to your list?".

## Grocery money, from the bank's side

- **Where each purchase went.** Every grocery card charge splits into eaten, wasted, still in the fridge,
  not added, and tax/other, adding up to the charge. Text `TRIPS` ("where did my money go?"); `MONEY`
  includes the last trip. In the app: Grocery budget → *Where your grocery money went*, tap a trip for the
  items in each part. With Kroger keys in the app, the trip also compares each line with today's live
  price at the nearest Kroger ("Did you overpay?"). Without keys it shows nothing estimated.
- **Savings streak.** Completed weeks in a row at or under the weekly budget, what budget sweeps moved
  to the Grocery Fund, and whether this week's waste is lower than last week's. It's on the budget card,
  in `MONEY`, and in the Sunday sweep offer.
- **Budget-aware list.** `LIST` and the app's Shopping list estimate the trip from what the household (or
  a roommate) last paid, against what's left of this week's budget. In the app, things never bought get a
  typical price marked with `~`.
- **Roommate settle-up.** Roommates each connect their own bank (their own Nessie customer) to the same
  app household. A card purchase knows who paid; SpacetimeDB's `item_use` log (−1 in the app) and USED
  by text say who ate it. Whoever ate a roommate's groceries owes them that share, netted both ways.
  `SETTLE` shows the split and offers "Send Sam $8 from Everyday Checking? Reply YES"; the app's Pay button
  does the same after a confirmation. Paying is a Nessie transfer between the two checking accounts, in
  whole dollars (cents stay on the tab), recorded so it's never paid twice. The creditor can tap *Ask*
  to text the debtor their split.

Demo: Settings → Bank demo → *Add a roommate* creates Sam with their own card and a weekly basket
(`POST /demo/roommate?app_household_id=…`), then *Sam uses…* simulates Sam texting USED
(`POST /demo/roommate/use?household_id=…`). `GET /demo/settle`, `POST /demo/settle/pay` and
`POST /demo/settle/ask` back the app. App −1 taps only count once the updated module in `server/` is
published; USED by text counts either way.

## People in the loop (Photon)

- **Household group chat.** Add the agent's number to an iMessage group with your roommates. The first
  member who texts there links the group to their household; after that it answers any member, and
  replies go to the whole group. Numbers it doesn't know are ignored. "who's grabbing milk?" puts milk on
  the list and asks the group; "I will" (or "I'll get eggs") claims it. Claims show in `LIST` and on the
  app's Shopping list ("Sam's grabbing it"), and swiping right in the app claims too. Money never moves
  from a group: a YES there to a transfer or settle-up is refused.
- **Photos.** Text a photo of a receipt or of your fridge. Gemini (`LLM_API_KEY`) reads it, the items are
  matched to the catalog, and the agent lists them: "Add these 6? Reply YES to add all, or a number to
  drop one." Fridge photos skip what's already tracked. Nothing is added without the YES.
- **Barcodes (no key needed).** Text a photo of a product's barcode. The server decodes it (zxing-cpp),
  looks it up on Open Food Facts, and matches it to the catalog: "🏷️ Scanned: 1) 🥛 whole milk (Horizon
  Organic Whole Milk). Add it?" Things the fridge doesn't track (chips, soda) are named and skipped. If
  Open Food Facts doesn't know the code and `LLM_API_KEY` is set, Gemini reads the packaging instead.
- **Answer in either place.** Every YES/NO question (stock a card purchase, add a photo's items, add
  staples, still have it?, budget sweep, settle-up) is also posted to SpacetimeDB's `approval` table. The
  app shows it under *Waiting on a yes* with Yes / Not now. Whichever answer comes first wins; the other
  side updates live, and the household gets a text saying who answered. Money questions only count from
  the account holder; anyone else's tap is refused and the question reopens.
- **Tapbacks.** 👍 or ❤️ on the message that asked a question means YES, 👎 means NO. A tapback never
  moves money ("reply with a typed YES"), and a tapback on an older message is ignored.
- **Typing.** The agent shows "…" while it works on a reply (`POST /spaces/{id}/typing`).
- **Webhooks by default.** Set `PUBLIC_URL` (e.g. a Cloudflare tunnel) and the server registers its own
  Photon webhook destination at startup and keeps the signing secret. While webhooks arrive, polling
  drops to every 15 s as a safety net.

Demo: `POST /demo/mock/text` takes `"group": "flat"` to speak in a simulated group chat. These need the
updated module in `server/` published; without it the app simply shows no approvals.

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

Polling (`list_messages` every 2 s) is the default and needs no public URL. For webhooks, set
`PUBLIC_URL` to the server's public address (it registers `/photon/webhook` with Photon at startup), or
add a destination in the Photon dashboard yourself and set `PHOTON_WEBHOOK_SECRET`. Signatures are verified with `standardwebhooks` against the raw body,
duplicates are dropped by `webhook-id`, and polling keeps running as the fallback (messages are
deduped by ID, so nobody gets two replies).

## How it fits together

```
app/
  main.py        FastAPI app + loops: Photon poll (2 s), Nessie sync (5 s demo / 60 s), scheduler,
                 SpacetimeDB sync + live subscriptions
  config.py      env settings; mocks switch on when a key is missing
  clock.py       the only "now"; demo time-skip is an offset stored in SQLite
  models.py      SQLite tables (households, members, items, list, waste, pending actions, …)
  households.py  provisions a synthetic Nessie customer + Everyday Checking + Grocery Fund
  money.py       purchase breakdown, savings streak, list estimate, roommate settle-up
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
