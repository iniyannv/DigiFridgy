# DigiFridgy two-phone demo recording

Recorded 2026-11-08 at 10:37:56. Both files start at the same moment, so timecodes line up.

- `phoneA_alex.mp4`: iPhone 17 Pro, "Alex", who creates the household (9:50)
- `phoneB_jordan.mp4`: iPhone 18 Pro, "Jordan", who joins with the code (8:22; it stops at Jordan's last on-screen change)
- `side_by_side.mp4`: both phones together, Alex on the left (9:50). Use this one for the voiceover.

The status bars are set to 9:41 with a full battery. Location is set to Richardson, TX, near UTD.

## Cuts

| Time | Phone | Note |
|---|---|---|
| ~1:15–1:40 | Alex | **Cut.** The first household got named "The" by mistake. Alex leaves it, and the clean take starts at 1:40. |
| ~8:50–end | Alex | **Cut.** The Milk allergen toggle doesn't stay on (app bug, see below). |

## Beats, in order (narration ideas)

1. **0:00 Alex: onboarding.** Tap "Start without an account".
2. **Alex creates "The Apartment"** (clean take from ~1:40), then opens Settings to show invite code `NJUQ2D` and "Members 1".
3. **Jordan opens the app** on the second phone, enters `NJUQ2D`, and sees the toast "Joined The Apartment".
4. **3:24 Alex seeds the fridge with real barcodes** (Settings → Developer → Seed demo with real barcodes). *VO: "Thirteen real products with their UPCs."* Then **Jordan's empty fridge fills in live**: 13 items, 5 to use this week, a Nutri-Score chart, and a possible-recall banner.
5. **Jordan scrolls the fridge.** It has Expired / Use soon / Later sections, real Open Food Facts photos, counts (eggs ×12), and "Est." estimated dates.
6. **Jordan opens the Greek yogurt.** It shows Nutri-Score B, a Nutrition Facts label, and a Milk allergen chip.
7. **Find cheapest nearby:** a map of stores around Richardson, with live Kroger prices first and "Sample price" badges on the other stores. (Includes a location prompt; trim it if you want.)
8. **Alex opens Recipes.** It's ranked by what expires first, with "Cook with" chips. The top result is a Lemonade Tart that "Uses 3 expiring".
9. **Alex opens the recipe,** hearts it to save it, sees which fridge items it uses and their expiry dates, and adds the missing **vanilla extract** to the shopping list.
10. **Jordan opens the shopping list.** The vanilla extract from Alex is already there. Jordan adds **Strawberries**, then long-presses vanilla and picks **"I'll get it"** to claim it.
11. **Alex opens the Stores tab.** Jordan's strawberries and the claim marker show up. Alex taps **Price the whole list**: Target is cheapest at $23.54 with tax, saving $2.60 vs Aldi.
12. **Jordan opens the Sour Cream recall:** "Possible recall: check the brand", with the reason, recall ID and a link to the FDA notices.

## Not recorded

- **Receipt scan:** the buttons are commented out in `InventoryView.swift` in the current working copy.
- **Bank / card connect, budget card, and iMessage approvals:** these need the backend and a phone number, so they're not in this take.
- **Allergen toggle bug:** Settings → My allergens → Milk flips back off after a tap, and no error shows. `AppState.setAllergen` → `updateProfile` probably isn't saving (it may be related to leaving and recreating the household in the same session).
