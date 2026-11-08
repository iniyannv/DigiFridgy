# Critique: DigiFridgy project

- Owner: core-critique
- Language: en
- Status: draft
- Date: 2026-11-07
- Proposal: the repository as of commit `1447f14` (iOS app `DigiFridgy/`, backend `backend/`, SpacetimeDB module `server/spacetimedb/`)
- Goal it must achieve:
  - "A shared household fridge for iPhone … Scan barcodes and grocery receipts, see what expires first, get recipes that use it up, compare prices at nearby stores, and get alerted about food recalls." (README.md:3-5)
  - "Money only moves after you reply YES." (backend/README.md:6)
  - "A user only ever sees their own household; outsiders get empty results." (README.md:47-48)
  - Expiry "always labeled 'Est.' until the user sets the printed date" (README.md:152-153), and sample prices are "always badged **Sample price**" (README.md:158-160).

## Proposal in five lines
1. An iOS app keeps one shared fridge per household in SpacetimeDB, using per-caller views and reducers that check membership.
2. A FastAPI backend turns synthetic Nessie card purchases into fridge items and talks over iMessage (Photon).
3. A bridge syncs the backend's per-unit rows with the app's per-product rows using a three-way merge.
4. The backend moves money (budget sweep, roommate settle-up) after a YES over iMessage or a confirmed tap in the app.
5. The app estimates expiry, matches openFDA recalls, compares Kroger live prices against sample prices, and sends local reminders.

## Assumptions the proposal rests on
- Assumes: the demo server is not reachable from the internet, or `DEMO_TOKEN` is set (stated, backend/README.md:114)
- Assumes: whoever calls `/signup` with a phone number owns it (unstated)
- Assumes: whoever calls `/demo/settle/*` is the payer named in the query (unstated)
- Assumes: the debt doesn't change between the offer and the YES (unstated)
- Assumes: only one YES/NO question is open per household at a time, and the person replying knows which one (unstated)
- Assumes: Nessie POSTs either fail cleanly or succeed once (unstated)
- Assumes: the last 4 digits of a phone number are unique among households (unstated)
- Assumes: a SpacetimeDB reducer call that times out did not commit (unstated)
- Assumes: every row in `fridge_item.data` is valid app JSON (unstated)
- Assumes: the backend runs as a single process (unstated)
- Assumes: the item list only changes through this device's own saves, as far as reminders are concerned (unstated)
- Assumes: matching a recall on product name alone is precise enough to flag an item (unstated)
- Assumes: the SpacetimeDB anonymous token survives in the Keychain (unstated)
- Assumes: the backend's server URL and token reach the app build (unstated; `DIGIFRIDGEY_SERVER` is undefined in the xcconfigs)

## Findings
| # | Lens | Failure mode | Trigger | Impact | Severity | Likelihood | Test or mitigation | Where |
|---|------|--------------|---------|--------|----------|------------|--------------------|-------|
| 1 | Engineering: Security | Demo routes are open by default | Public host with `DEMO_TOKEN=""` | Anyone can pay, wipe every Nessie object for the key, and read state. Money and data are lost | blocking | medium | Refuse to start when public with no token; put the wipe behind an admin token | backend/app/config.py:41-42, demo/routes.py:26-35 |
| 2 | Any proposal: Goal alignment | `/demo/settle/pay` trusts the client's `household_id` and needs no YES. Defeats "Money only moves after you reply YES." | POST `household_id=<debtor>&to=<self>` | Transfer from another person's checking | blocking | medium | Derive the payer from the caller's SpacetimeDB token; test payer ≠ caller → 403 | demo/routes.py:312-321, money.py:297-309 |
| 3 | Engineering: Security | Signup with a registered phone relinks the household and rebinds the identity. Defeats "A user only ever sees their own household." | POST `/signup` with the victim's phone and the attacker's invite code | The victim's fridge syncs into the attacker's household; fake debts | blocking | medium | Signup never relinks an existing household; relink only by LINK from the phone | signup.py:90-129, 138-146 |
| 4 | Engineering: Timing | `pay()` recomputes the debt at YES time | Uses land between the offer and the YES | More money moves than was approved | blocking | medium | Pay the offered amount, abort if it changed; test amount drift | money.py:306-308, 354-355 |
| 5 | Engineering: State | YES answers the latest question of any kind, from any member; "ok", "sure" and "y" count | A sweep or settle offer replaces a nudge, someone replies "ok" | Money moves for an unintended question | blocking | medium | Supersede only within kind; exact YES from the addressed member for money | brain/pending.py:22-27, commands.py:253, router.py:44 |
| 6 | Engineering: Integration | Nessie POST is retried; a transfer is two calls | Timeout after commit, or the deposit fails | Double pay, or "nothing moved" after money left; no Settlement row, so it is paid again | blocking | low | No POST retries; record a pending Settlement before calling Nessie | nessie/client.py:63-77, 126-131, money.py:322-330 |
| 7 | Engineering: State | LINK leaves the household before joining and keeps the old merge state | `LINK <typo>` | Every backend unit is marked used/tossed (data loss) | blocking | medium | Join first; keep the link on failure; skip deletes when not a member | spacetime/bridge.py:200-212, 263-287 |
| 8 | Engineering: Security | Households are looked up by display name built from the last 4 digits | Two numbers with the same last 4 digits | Strangers share balances and can confirm each other's transfers | blocking | low | Key on the full normalized handle | households.py:35-37, 91-93 |
| 9 | Engineering: Security | `/demo/state` returns any household's phones, balances and conversation | `?household_id=N` | PII leak | high | medium | Caller-scoped state only | demo/routes.py:167-222 |
| 10 | Engineering: Security | Usage attribution can be spoofed (`log_use` name, `AppMember` overwrite) | A member logs uses or signs up with another's identity | Wrong debts | high | low | Check the item; take the name from the row; never overwrite `AppMember` | lib.rs:447-490, signup.py:138-146 |
| 11 | Engineering: Timing | Relative `increment_count` replays after a timeout | Commit lands, the reply is lost | Double decrement | high | low | `set_count_if(id, expected, new)` | bridge.py:314-332 |
| 12 | Engineering: Data | `count` has no upper bound; one row per unit in the bridge | `count=2000000000` | Backend stalls, DB grows | high | low | Clamp to 0..=999; cap in the bridge | lib.rs:402, 442, bridge.py:293-297 |
| 13 | Engineering: Data | One malformed `data` row aborts the household's sync | `data="x"` | Sync stops for good | high | low | Parse per row, skip bad rows | bridge.py:471, 516, 532 |
| 14 | Engineering: Security | Invite codes: 31^6, no rate limit, rotation, kick or GC; ghost members | Brute force, or a former roommate rejoins | Household data exposed | high | low | 8 characters, rate limit, rotate on leave, kick reducer | lib.rs:15, 318-395 |
| 15 | Engineering: Security | Time-skip offset applies outside demo mode; negative skip allowed; stale offers never expire | Rewind, or a reused demo DB | Expired money offers revive; transfers future-dated | high | low | Offset only in demo; reject negatives; expire on each tick | clock.py:22-26, routes.py:89-92, pending.py:77 |
| 16 | Any proposal: Contradictions | STOP misses standard opt-out words; "hi" re-subscribes; STOP leaves money offers open | "CANCEL", "stop texting me" | User keeps getting texts; a later YES still pays | high | medium | Full opt-out keyword set; START only; cancel offers on STOP | router.py:38-45, commands.py:50 |
| 17 | Engineering: Security | LLM can emit the `settle` and `budget` intents | Misclassified text | Creates a settle offer or changes the sweep size | high | low | Keyword-only for money intents | router.py:14-15, llm.py:88 |
| 18 | Engineering: Consumers | Reminders ignore remote changes, sign-out and leave | A roommate or the bank adds or deletes an item | Missing or stale reminders; the next user inherits them | high | high | Reconcile pending notifications on every item update | AppState.swift:102-131, 161-213 |
| 19 | Any proposal: Goal alignment | Recall matching is name-only with no firm or date; the flag can't be cleared | Brandless "Baby Spinach" from a receipt | Permanent false recall alert | high | medium | "Possible" confidence, dismiss action, date filter | OpenFDARecallService.swift:73-79, AppState.swift:503 |
| 20 | Any proposal: Contradictions | Sample prices are shown without the badge | Shopping list `~`, map markers, price-drop alerts | Users take sample prices as real | high | high | Label everywhere; alerts only on live quotes | ShoppingListView.swift:17, 49, 77, PriceComparisonView.swift:94, 188-191, AppState.swift:540-563 |
| 21 | Any proposal: Contradictions | "Est." is dropped | Recipes, summary card, reminder title | Estimates read as facts | medium | high | One `expiryLabel` helper | RecipesView.swift:74, 166, FridgeSummaryCard.swift:26, LocalNotificationService.swift:32 |
| 22 | Engineering: Data | Expiry stored as an instant and shown by local day; short windows get no reminder; a re-scan inherits expiry and recall | Other time zone, late add | Off-by-one days; missed reminders | medium | medium | Store calendar dates; reminder at min(9 AM day before, now+1h) | ShelfLifeService.swift:49, FridgeItem.swift:107-111, LocalNotificationService.swift:29 |
| 23 | Engineering: Integration | Recall false negatives: no paging, no FSIS, one-word names, UPC-E | A recall beyond 200 rows, meat recall, UPC-E barcode | A real recall is missed | medium | medium | Paging, UPC-E expansion, FSIS if available | OpenFDARecallService.swift:17, 79, 85 |
| 24 | Engineering: Timing | `runChecks` and `adjustCount` write stale copies | A roommate edits during the awaits | Edit overwritten | medium | medium | Re-read by ID after each await; single-flight | AppState.swift:403, 495-508 |
| 25 | Engineering: Timing | The bridge's delete beats a concurrent +1 | +1 during a sync round | +1 lost | medium | low | Conditional write | bridge.py:239, 311-312 |
| 26 | Engineering: State | `log_use` fallback is a process-wide sticky flag; batches over 1000 fail forever | Any "404" error text | Usage log lost; settle-up wrong | medium | low | Per-household TTL flag; chunking | bridge.py:353, 380-384 |
| 27 | Engineering: Data | App decrement takes expired units first and marks them tossed | Eat one item while an older unit has expired | Eating counted as waste | medium | medium | Fresh units first | bridge.py:281-285 |
| 28 | Engineering: Integration | Three failed polls end the live streams for good | About 6 s offline | Fridge stops updating | medium | medium | Keep retrying; resubscribe on activation | SpacetimeHouseholdRepository.swift:160-169 |
| 29 | Engineering: Consumers | A new view column disables the socket; decoding runs on the main actor | Module publish adds a column | Every client polls every 2 s; UI jank | medium | low | Ignore unknown columns; decode off the main actor | SpacetimeSubscription.swift:68-74, 186-187 |
| 30 | Engineering: Security | Keychain status ignored; not `ThisDeviceOnly`; backend tokens in plaintext | Keychain save fails | Identity and household lost | medium | low | Check `OSStatus`; `ThisDeviceOnly` | SpacetimeClient.swift:167, models.py:149 |
| 31 | Engineering: Security | PII and tokens in logs and URLs; voice `?handle=` reaches any household | Access logs, mock Photon log | Phone numbers and message text leak | medium | high | Mask handles; header-only tokens | signup.py:69, photon/client.py:225, routes.py:30 |
| 32 | Engineering: Data | Receipt parser drops "TOTAL", "CHIP" and "MEMBER" product lines and time lines; the quantity carries over; the price is discarded | "FAGE TOTAL 0% 1.99" | Items missing from the review screen | medium | medium | Whole-line patterns; keep the price | ReceiptParser.swift:21-28, 36, 52, 102 |

Also recorded, lower impact (low severity unless noted):
- Bank server URL and token undefined in the xcconfigs, falling back to localhost (medium). Info.plist:13-15, BankStore.swift:171, 198.
- Kroger token stampede, no 429 handling, caches that never expire (medium). LiveKrogerService.swift:7-27.
- Swallowed errors (medium). AppState.swift:129-131, 532.
- Hardcoded background task ID. AppState.swift:21.
- Leftover `useMocks`. AppServices.swift:58.
- Edamam key in the URL (accepted as demo-only).
- Item ID existence leak. lib.rs:403.
- Every update wakes all households. bridge.py:548.
- No confirmation on "Buy with card" and "+N days". BankViews.swift:382-389.
- Missing tests for every money and auth path above (medium, Any proposal: Measurement).

## Alignment with the goal
- **The app's fridge, scan, recipe and price features address the first goal.** However, findings 18-23 weaken the "see what expires first" and "alerted about food recalls" parts.
- **The money path addresses "Money only moves after you reply YES" only for the iMessage sweep.** The app's settle path (finding 2) and the amount drift (finding 4) are not covered, and findings 5, 6 and 17 bypass it.
- **"A user only ever sees their own household" holds inside SpacetimeDB views.** It is defeated at the backend edge (findings 3, 8, 9).

## Contradictions
- backend/README.md:6 "Money only moves after you reply YES" vs demo/routes.py:312-321 and money.py:306-308.
- README.md:47-48 "A user only ever sees their own household" vs signup.py:90-129, households.py:35, demo/routes.py:167-222.
- README.md:152-153 "always labeled 'Est.'" vs RecipesView.swift:166-167, LocalNotificationService.swift:32.
- README.md:158-160 "always badged **Sample price**" vs ShoppingListView.swift:49, PriceComparisonView.swift:188-191.

## What-if scenarios tested (when fewer than two findings)
Not needed: 32 findings.

## Verdict
needs revision

Conditions:
1. Demo routes are refused or authenticated when public (#1).
2. The payer comes from the caller (#2).
3. Signup never relinks (#3).
4. Pay the approved amount (#4).
5. Kind-scoped exact YES (#5).
6. Idempotent transfers (#6).
7. Join before leave (#7).
8. Key households on the full handle (#8).
9. Caller-scoped state (#9).
10. Validate usage attribution (#10).
11. Conditional count writes (#11, #25).
12. Count bounds (#12).
13. Per-row parse (#13).
14. Invite code hardening (#14).
15. Demo-only clock (#15).
16. Full STOP handling (#16).
17. Keyword-only money intents (#17).
18. Reminder reconcile (#18).
19. Recall confidence and dismiss (#19).
20. Price labels (#20).
21. Est. helper (#21).
22. Calendar dates (#22).
23. Recall coverage (#23).
24. Fresh reads (#24).
25. Per-household log_use fallback (#26).
26. Fresh-first decrement (#27).
27. Resilient feed (#28, #29).
28. Keychain checks (#30).
29. PII masking (#31).
30. Parser patterns (#32).

Next: implementation per `/Users/iniyann/.claude/plans/this-project-create-a-quiet-badger.md`, then re-run core-critique, because every condition above is a code change that needs a check.

## Assumptions
- Assumption: SpacetimeDB returns HTTP 404 for an unknown reducer (not verified; affects findings 26 and 28).
- Assumption: openFDA's 90-day window can exceed 200 results (not verified; finding 23).
- Assumption: the app ships without `DIGIFRIDGEY_TOKEN` set, because no xcconfig defines it (finding 1 likelihood).
- Assumption: the webhook library's default timestamp tolerance is about 5 minutes (not verified; no finding depends on it).
