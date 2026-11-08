# DigiFridgy

A shared household fridge for iPhone (HackUTD 2026). Scan barcodes and grocery receipts, see what
expires first, get recipes that use it up, compare prices at nearby stores, and get alerted about
food recalls.

iOS 26 · Swift 6 · SwiftUI · `@Observable` · Firebase (Auth + Firestore) · no other third-party deps.

## Quick start (offline demo, no setup)

```bash
open DigiFridgy.xcodeproj
```

Run on an iPhone 17 simulator. Without `GoogleService-Info.plist` the app starts in **mock mode**
automatically: data stays on the device, product lookups / recipes / prices use bundled sample data,
and OCR + notifications are still real. You can also force mock mode with the `--mock` launch
argument (Edit Scheme → Arguments, already listed but disabled) or Settings → Demo tools.

## Full setup (live services)

1. **Firebase** — create a project, add an iOS app with bundle id `com.iniyann.digifridgy`
   (or change `PRODUCT_BUNDLE_IDENTIFIER`), download `GoogleService-Info.plist` into
   `DigiFridgy/Resources/` (the folder is auto-included in the target; the file is gitignored).
   Enable **Authentication → Email/Password and Anonymous**, and **Firestore**.
2. **Firestore rules** — paste [`firestore.rules`](firestore.rules) into Firestore → Rules → Publish.
3. **API keys** — `cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig` (already done once)
   and fill in:
   | Key | Where |
   |---|---|
   | `EDAMAM_APP_ID`, `EDAMAM_APP_KEY` | developer.edamam.com → Recipe Search API (developer plan) |
   | `KROGER_CLIENT_ID`, `KROGER_CLIENT_SECRET` | developer.kroger.com → register app, scope `product.compact` |
   | `CALORIENINJAS_KEY` | calorieninjas.com/api |

   Values must not contain `//` (xcconfig comment). Any key left empty falls back to its mock.
   Open Food Facts and openFDA need no key.
4. **Signing** — pick your (free) team under Signing & Capabilities to run on a phone.
   Free provisioning profiles expire after 7 days.

Settings → **Services** shows which integrations are live vs mock.

> ⚠️ **Secrets in the app bundle are demo-only.** Anything in `Info.plist` can be extracted from the
> IPA. A real release must proxy Edamam, Kroger and CalorieNinjas through a backend.

## Demo script (~3 min)

1. **Scan** milk + yogurt barcodes (simulator: tap a test barcode in the scan sheet) → items appear
   with an **Est.** expiry; a second device in the same household updates live.
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
    Live/       FirebaseAuth, Firestore repo, Open Food Facts + CalorieNinjas, Edamam, openFDA,
                Kroger (OAuth2 client credentials), MapKit store search, Vision OCR,
                Foundation Models receipt normalizer, local notifications
    Mock/       Offline implementations + DemoData (seed household, products, recipes)
    ShelfLifeService, ReceiptParser, RecipeScorer, MockPriceService (pure, unit-tested)
  Features/   Onboarding, Inventory, Scan, ItemDetail, Nutrition, Recipes, Stores, Settings, Common
  Resources/  shelf_life.json (58 categories → fridge days, keywords, baseline price), Assets
Config/       Base.xcconfig (includes gitignored Secrets.xcconfig), Info.plist
DigiFridgyTests/  Swift Testing: parser, shelf life mapping, recipe scoring, mock price determinism,
                  DTO decoding, recall matching
firestore.rules
```

Data flow: views read `AppState` from the environment; `AppState` calls services and owns the
Firestore snapshot listener (`AsyncThrowingStream`) that keeps `items` live across household members.

Firestore layout:

```
users/{uid}                         householdId, displayName, allergens, searchRadiusMiles, watchlist
households/{hid}                    name, inviteCode, memberUids, createdAt
households/{hid}/items/{id}         FridgeItem (nutrition + allergens snapshotted at scan time)
households/{hid}/shopping/{id}      shopping list
households/{hid}/priceHistory/{upc} lastPrice, lastStoreId, checkedAt
```

Expiry is **estimated** from category shelf life (approximating USDA FoodKeeper fridge times) and
always labeled "Est." until the user sets the printed date.

Receipt names are expanded by the on-device Foundation Model (Apple Intelligence devices) with a
dictionary fallback; the review screen is mandatory.

Prices: Kroger is live (when keys are set). Walmart, H-E-B, Target, Aldi and Tom Thumb show real
nearby locations from MapKit with deterministic sample prices (±20% around the Kroger/category
price), always badged **Sample price**.

## Build & test from the command line

```bash
xcodebuild -scheme DigiFridgy -destination 'platform=iOS Simulator,name=iPhone 17' build
```

```bash
xcodebuild -scheme DigiFridgy -destination 'platform=iOS Simulator,name=iPhone 17' test
```
