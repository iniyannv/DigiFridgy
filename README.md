# DigiFridgy

A shared household fridge for iPhone (HackUTD 2026). Scan barcodes and grocery receipts, see what
expires first, get recipes that use it up, compare prices at nearby stores, and get alerted about
food recalls.

iOS 26 · Swift 6 · SwiftUI · `@Observable` · **SpacetimeDB 2.x** (household data, Rust module) · Firebase Auth
(optional, for email sign-in) · no other third-party deps.

## iMessage + bank backend: Nessie + Photon

[`backend/`](backend/README.md) is a Python FastAPI service that turns synthetic grocery
transactions from Capital One's Nessie API into a fridge inventory and talks to you over iMessage
through Photon: stock alerts, expiry nudges, food-waste dollars, and a YES-confirmed budget sweep
into a Grocery Fund account. It runs offline with labeled mocks; see its README.

It shares the app's fridge through SpacetimeDB: bank purchases appear in the app, items scanned in
the app show up over iMessage, and "used" / "tossed" on either side updates the other.

In the app, the bank is part of the household rather than a tab of its own: **Connect your bank**
(on the Fridge tab or in Settings → Bank & iMessage) signs up a phone number and joins the bank to
the current household. Card purchases then land in the fridge with their store and price (marked
with a card icon), a weekly budget card sits under the fridge summary, and Settings → Bank demo has
the buy / time-skip / sweep controls. Over iMessage, text **APP** for the invite code, or
**LINK <code>** to attach to a household that already exists in the app.

## Quick start (offline demo, no setup)

```bash
open DigiFridgy.xcodeproj
```

Run on an iPhone 17 simulator. Out of the box the app talks to the published SpacetimeDB database
(`digifridgy-hud4l` on Maincloud), and "Try it" signs in with an anonymous SpacetimeDB identity. APIs
without keys use bundled sample data. For a fully offline demo, use **mock mode**: the `--mock` launch
argument (Edit Scheme → Arguments, already listed but disabled) or Settings → Demo tools. Mock mode keeps
data on the device; OCR and notifications are still real.

## Data: SpacetimeDB

The server module lives in [`server/spacetimedb/src/lib.rs`](server/spacetimedb/src/lib.rs) (Rust).

- **Tables (all private):** `user_profile`, `household`, `household_member`, `fridge_item`,
  `shopping_item`, `price_history`, `item_use` (who used what, for splitting grocery costs between roommates),
  `approval` (questions from the iMessage agent waiting on a YES, answerable in the app). Item, profile and shopping payloads are the app's JSON in a `data`
  column, so app models can change without a schema migration.
- **Reads:** per-caller views `my_profile`, `my_household`, `my_items`, `my_shopping`, `my_prices`,
  `my_item_uses`, `my_approvals`. A user
  only ever sees their own household; outsiders get empty results.
- **Writes:** reducers check membership against `ctx.sender()`: `save_profile`, `create_household`,
  `join_household` (6-char invite code), `leave_household`, `upsert_item`, `upsert_items` (receipt batch),
  `increment_count`, `use_item` (−1 in the app: lowers the count and records who used it), `log_use` (the
  backend records USED by text), `delete_item`, `save_shopping_item`, `delete_shopping_item`, `save_price`,
  `post_approval` / `decide_approval` / `close_approval`.
  The app and backend fall back to the older reducers until a module with `use_item` is published.
- **Client:** there's no official Swift SDK, so the app has a small client of its own, with no
  dependencies. Reducers go through `POST /v1/database/:db/call/:reducer`
  ([`SpacetimeClient.swift`](DigiFridgy/Services/Networking/SpacetimeClient.swift)). Live data comes from a
  WebSocket subscription (`/v1/database/:db/subscribe`, subprotocol `v1.json.spacetimedb`) to `my_items`
  and `my_shopping` ([`SpacetimeSubscription.swift`](DigiFridgy/Services/Networking/SpacetimeSubscription.swift)):
  the server sends the initial rows, then the inserts and deletes of every transaction that touches them,
  from any phone or the iMessage backend (about 50 ms end to end on Maincloud). While the socket is down,
  the app polls the views over `POST /v1/database/:db/sql` every 2 s and reconnects with backoff.

Publish changes to the module:

```bash
cd server && spacetime publish --yes
```

Watch reducer errors and logs:

```bash
cd server && spacetime logs -f
```

Change the target server or database with `SPACETIME_HOST` / `SPACETIME_DB` in
`Config/Secrets.xcconfig` (defaults in `Config/Base.xcconfig`; no `https://` because xcconfig treats
`//` as a comment).

## Sign-in

- **Without Firebase** (default): "Try it" calls `POST /v1/identity` and keeps the SpacetimeDB token in
  the Keychain. Email sign-in is hidden.
- **With Firebase Auth:** add `GoogleService-Info.plist` to `DigiFridgy/Resources/` (gitignored) and
  enable **Email/Password** and **Anonymous** sign-in in the Firebase console (Firestore isn't used). The
  app then sends the Firebase ID token to SpacetimeDB as its OIDC bearer token. SpacetimeDB derives the
  user's Identity from the token's `iss` + `sub`, so a user keeps the same household on every device.
  *Not yet verified against Maincloud; if requests fail with "rejected the sign-in token", check
  `spacetime logs`.*

## API keys (optional)

`cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig` (already done once) and fill in:

| Key | Where |
|---|---|
| `EDAMAM_APP_ID`, `EDAMAM_APP_KEY` | [developer.edamam.com](https://developer.edamam.com/edamam-recipe-api), Recipe Search API (Developer plan) |
| `KROGER_CLIENT_ID`, `KROGER_CLIENT_SECRET` | [developer.kroger.com](https://developer.kroger.com/), register an app, scope `product.compact` |
| `CALORIENINJAS_KEY` | [calorieninjas.com/api](https://calorieninjas.com/api) |
| `WALMART_CONSUMER_ID`, `WALMART_KEY_VERSION`, `WALMART_PRIVATE_KEY` | [walmart.io](https://walmart.io/), Affiliate API: upload your RSA public key, put the private key in as one base64url line (command in `Secrets.example.xcconfig`) |

Values must not contain `//`. Any key left empty falls back to its mock. Open Food Facts and openFDA
need no key. To run on a phone, pick your (free) team under Signing & Capabilities; free provisioning
profiles expire after 7 days.

Settings → **Services** shows which integrations are live vs mock.

> ⚠️ **Secrets in the app bundle are demo-only.** Anything in `Info.plist` can be extracted from the
> IPA. A real release must proxy Edamam, Kroger, Walmart and CalorieNinjas through a backend.

## Demo script (~3 min)

1. **Scan** milk + yogurt barcodes (simulator: tap a test barcode in the scan sheet) → items appear
   with an **Est.** expiry; a second device that joined with the invite code updates instantly.
2. **Scan a receipt** (+ → Scan receipt → camera / photo / sample receipt) → review → 6+ items added.
3. Open the **yogurt** → FDA-style nutrition label, Nutri-Score, milk allergen warning
   (turn on *Milk* in Settings → My allergens).
4. **Recipes** tab → top recipe uses the spinach expiring tomorrow.
5. Item → **Find cheapest nearby** → map + list; Kroger live price vs badged *Sample price* rows.
6. Settings → **Simulate recall** → red banner on the item + notification.

Settings → Demo tools also has *Seed demo household* (~14 items), *Simulate price drop*,
*Test expiry notification* and *Run checks now* (background refresh is unreliable on stage).

Real barcodes that resolve on Open Food Facts: `0078742351865` (GV whole milk),
`0070470003023` (Yoplait blueberry), `0078742127088` (GV eggs), `0099482434090` (365 cheddar),
`0742365264450` (Horizon milk), `0048500202807` (Tropicana OJ).

## Architecture

```
DigiFridgy/
  App/        DigiFridgyApp (entry, BG refresh), AppState (session + all mutations), AppServices (DI)
  Models/     FridgeItem, Nutrition/Allergen, Household/UserProfile, Recipe, Store/PriceQuote, Recall
  Services/   ServiceProtocols.swift — every service is a protocol with Live + Mock implementations
    Networking/ APIClient, SpacetimeClient (HTTP reducers + view queries), Secrets, Keychain
    Live/       SpacetimeDB repo + identity auth, FirebaseAuth, Open Food Facts + CalorieNinjas, Edamam, openFDA,
                Kroger (OAuth2 client credentials), MapKit store search, Vision OCR,
                Foundation Models receipt normalizer, local notifications
    Mock/       Offline implementations + DemoData (seed household, products, recipes)
    ShelfLifeService, ReceiptParser, RecipeScorer, MockPriceService (pure, unit-tested)
  Features/   Onboarding, Inventory, Scan, ItemDetail, Nutrition, Recipes, Stores, Settings, Common
  Resources/  shelf_life.json (58 categories → fridge days, keywords, baseline price), Assets
Config/       Base.xcconfig (includes gitignored Secrets.xcconfig), Info.plist
DigiFridgyTests/  Swift Testing: parser, shelf life mapping, recipe scoring, mock price determinism,
                  DTO decoding, recall matching
server/       SpacetimeDB module (Rust): tables, per-caller views, membership-checked reducers
```

Data flow: views read `AppState` from the environment; `AppState` calls services and consumes the
repository's `AsyncThrowingStream`s of items and shopping entries, fed by one SpacetimeDB subscription so
every household member (and the iMessage backend) sees each change as it commits.

Expiry is **estimated** from category shelf life (approximating USDA FoodKeeper fridge times) and
always labeled "Est." until the user sets the printed date.

Receipt names are expanded by the on-device Foundation Model (Apple Intelligence devices) with a
dictionary fallback; the review screen is mandatory.

Prices: Kroger is live per store (when keys are set). Walmart shows the walmart.com price from the Walmart
Affiliate API on every nearby Walmart (badged **Walmart.com**, since shelf prices can differ). H-E-B, Target, Aldi
and Tom Thumb (and Walmart without a key) show real nearby locations from MapKit with deterministic sample prices
(±20% around the Kroger/category price), always badged **Sample price**.

## Build & test from the command line

```bash
xcodebuild -scheme DigiFridgy -destination 'platform=iOS Simulator,name=iPhone 17' build
```

```bash
xcodebuild -scheme DigiFridgy -destination 'platform=iOS Simulator,name=iPhone 17' test
```
