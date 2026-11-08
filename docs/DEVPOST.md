## Inspiration

Somewhere between 30 and 40% of the food supply in the US gets thrown away, and a lot of that happens in our own kitchens. In a shared apartment it's worse: nobody knows who bought the spinach, nobody notices it's going bad until it's slime, and three people buy milk in the same week. We wanted a fridge the whole household can see, that tells you what to eat first and keeps track of the money without anyone opening a spreadsheet.

We also noticed that your bank already knows what you bought at the grocery store. So we asked: what if your card purchase stocked your fridge for you, and your fridge could just text you?

## What it does

DigiFridgy is one shared household fridge with three parts: an iPhone app, a bank connection that fills it for you, and a contact you can text or call. All three read and write the same data, so a change in one shows up everywhere.

**The app**

*Why:* the fridge needs a place where you can see everything at once: what's in it, what expires first, what to cook, and where to buy what's missing. Scanning and browsing are easiest on a screen.

- **Add food fast.** Scan a barcode, or snap a grocery receipt and review the items before they're added. Abbreviated receipt names ("GV WHL MLK") are expanded on-device with Apple's Foundation Models.
- **See what expires first.** Every item gets an estimated expiry from its food category (based on USDA FoodKeeper fridge times), clearly marked "Est." until you enter the printed date. You get a reminder before things go bad.
- **Cook what you have.** Recipes are ranked by how many of your soon-to-expire ingredients they use. Search, filter by time, diet and difficulty, and add whatever's missing to the shared shopping list in one tap.
- **Know what's in it.** Nutrition labels, Nutri-Score, and allergen warnings for each household member, plus alerts when an item matches an FDA recall.
- **Find the best price.** Compare prices at nearby stores on a map, with live Kroger and Walmart.com prices.
- **Share everything live.** Roommates join with a 6-character invite code. When someone scans, uses, or tosses something, everyone's phone updates in about 50 ms.

**The bank**

*Why:* food trackers usually die when people get tired of logging every grocery trip by hand. Your bank already records every grocery trip, so we let the purchase itself fill in what you bought. Knowing what each item cost also lets us show waste in dollars, which is more motivating than a count of items.

- **Your card stocks the fridge.** Connect a (synthetic) Capital One account through Nessie. When you buy groceries, the items on that purchase come up for review, like a scanned receipt, and go into the fridge with their store and price once you reply YES or pick them in the app. Banks don't get item-level data today, so our demo purchases carry their item list with them, the way itemized merchant data would in a real bank.
- **See where your money went.** Every grocery trip is broken down into eaten, wasted and still in the fridge, next to a weekly budget and a savings streak.
- **Save what's left.** At the end of the week, DigiFridgy offers to move unspent grocery money into a Grocery Fund account.
- **Split costs fairly.** Roommates each connect their own card, and settle-up is based on who actually ate what, not an even split of the receipt.
- **Money only moves after you say yes.** Every transfer needs an explicit YES by text or a confirmed tap in the app.

**iMessage and phone**

*Why:* the moment you need your fridge is usually when you're not looking at an app: standing in a store aisle, cooking, or about to throw something out. Texting is something everyone already does, and a phone call works with your hands full. So the fridge also lives in your messages, and it reaches out first when food is about to go bad.

- **Text your fridge.** "What's expiring?", "do I have eggs?", "what can I make with the spinach?", "finished the milk". Roommates can coordinate too: ask "who's grabbing milk?" and whoever replies "I will" claims it.
- **Get nudged.** It texts you when something is about to expire, asks "still have it?" the day before, and offers to add a staple to your list when you run out.
- **Approve bank actions.** Budget sweeps and roommate payments arrive as a question, and you reply **YES** to send them.
- **Call your fridge.** A voice agent answers the phone, checks what you have, adds to your list, and texts you recipes.

## How we built it

- **iOS app:** Swift 6 and SwiftUI on iOS 26, with `@Observable` state. Every service is a protocol with a live and a mock version, so the app runs fully offline for demos. Apple Vision does receipt OCR, Foundation Models cleans up receipt item names, and MapKit finds nearby stores.
- **Shared data:** SpacetimeDB on Maincloud, with a Rust module of tables, per-user views, and reducers that check household membership on every write. A user only ever sees their own household. There's no official Swift SDK, so we wrote a small dependency-free client: HTTP for reducer calls and a WebSocket subscription for live updates, with polling and reconnect as a fallback.
- **Backend:** Python and FastAPI. It turns Capital One **Nessie** purchases into fridge items and talks to people over iMessage through **Photon**. A bridge syncs the backend's fridge with the app's through SpacetimeDB, both ways.
- **AI:** Gemini classifies messages our keyword rules don't recognize, answers open questions ("is wilted spinach still ok?") using the household's fridge as context, and writes recipes from what you have. It can't move money or change the fridge on its own; those commands have to be typed.
- **Voice:** An ElevenLabs conversational agent on a Photon phone number over SIP, with five tools that call our backend (fridge summary, check an item, add to list, what's expiring, recipe ideas).
- **Data sources:** Open Food Facts and CalorieNinjas (products and nutrition), Edamam (recipes), openFDA (recalls), Kroger and the Walmart Affiliate API (prices).
- **Tests:** Swift Testing for the parser, shelf-life mapping, recipe scoring and sync logic, and pytest for the backend.

## Challenges we ran into

- **Two fridges that had to become one.** The backend tracks one row per unit (so it can count waste in dollars), while the app tracks one row per product with a count. We sync them with a three-way merge against the last agreed counts, so if someone texts "used the milk" while a roommate taps −1 in the app, both changes add up instead of one overwriting the other.
- **No Swift SDK for SpacetimeDB.** We read the HTTP and WebSocket protocol and wrote our own client, including subscription handling and recovery when the socket drops.
- **Banks don't know what's in your cart.** Card transactions don't carry line items, so each synthetic Nessie purchase carries its items in the description field. We also found Nessie only stores whole dollars, balances never change on their own, and transfers have no destination, so we compute running balances ourselves and record a transfer as a withdrawal plus a matching deposit.
- **Making money safe.** Halfway through we ran a full critique of our own project and found real problems: a "YES" could answer the wrong question, a retried request could pay twice, and one endpoint trusted the client about who was paying. We fixed all of them: money only moves on the exact word YES from the person who was asked, each transfer is claimed in the database before Nessie is called, and the payer always comes from the caller's own login.
- **The voice agent.** ElevenLabs was failing tool calls before they ever reached us because the caller's number arrived empty in a query parameter. Moving it to a header fixed it.
- **Being honest about estimates.** Expiry dates and some store prices are estimates. We made sure "Est." and "Sample price" badges show up everywhere those numbers appear, including notifications and the map.

## Accomplishments that we're proud of

- The same fridge, live, across several iPhones, iMessage and a phone call. Scan something in the app and it's in the next text.
- Buying groceries with your card fills the fridge for you, and the app can show you exactly how much of that trip you actually ate.
- Roommate settle-up based on who used what, instead of splitting the receipt evenly.
- The AI helps without being trusted with anything risky: it can talk and suggest, but money and fridge changes always go through a human.
- The whole thing runs offline with labeled mock data, so the demo works even when the Wi-Fi doesn't.

## What we learned

- Real-time sync is easy until two people edit the same thing at once. Designing the merge took longer than writing the client.
- Keep the LLM where it adds value (understanding messy texts, writing recipes) and keep plain rules for anything that touches money.
- Reviewing our own work with fresh eyes partway through was worth the time; it caught bugs we would have demoed.
- APIs rarely behave exactly like their docs. Testing Nessie against the live server early saved us from building on wrong assumptions.

## What's next for DigiFridgy

- Itemized purchase data from real banks and grocery loyalty programs, so receipts aren't needed at all.
- Reading printed expiry dates straight from the package with the camera.
- Moving all third-party API keys behind our backend before any public release.
- Smarter shopping: a list that predicts what you'll run out of and picks the cheapest nearby store for the whole trip.
- Food-waste reports over time, and donation suggestions for food you won't get to.

## Built with

swift · swiftui · spacetimedb · rust · python · fastapi · capital-one-nessie · photon · imessage · gemini · elevenlabs · apple-vision · apple-foundation-models · mapkit · open-food-facts · edamam · openfda · kroger-api · walmart-api · calorieninjas · firebase-auth
