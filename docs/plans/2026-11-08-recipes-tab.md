# Recipes tab: search, filters and fixes

Reviewed on the iPhone 17 Pro simulator after **Seed demo household** (15 items, live Edamam).

## What users run into today

| # | Problem | Why it happens |
|---|---|---|
| 1 | Every result is the same dish: ~20 near-identical chicken / spinach / strawberry salads. | The first query ("spinach chicken breast strawberries") fills the 20-result cap, so the single-ingredient queries never run. Near-duplicate titles ("Spinach and Strawberry Salad", "Chicken Strawberry Spinach Salad Recipe 5") aren't merged. |
| 2 | No way to search for something specific ("tacos", "soup"). | No search field. |
| 3 | No way to narrow by meal, dish type, cuisine, diet, or cooking time. | No filters; the service only takes allergen labels. |
| 4 | No way to pick which fridge items to cook with. | Queries are always built from the five soonest-expiring items. |
| 5 | Cards are very long: "spinach (Est. exp. tomorrow), chicken breast (Est. exp. tomorrow) …" repeats on every card. | Expiry text is shown per ingredient on every card. |
| 6 | "Uses 3 e…" chip is truncated; source names wrap mid-word ("eatthismuch.-com"). | Chip shares a row with a flexible source label. |
| 7 | Some thumbnails stay as blank grey boxes. | Edamam image links are signed and expire after an hour, but results are cached for six hours; a failed image shows the loading placeholder forever. |
| 8 | Tapping a recipe jumps straight to a website: you can't see the ingredient list, what you already have, or add the missing items to the shopping list. | No detail screen. |
| 9 | No way to keep a recipe you liked. | No saving. |
| 10 | No way to sort (quickest, fewest missing, lightest). | Fixed "use expiring first" order. |
| 11 | With an empty fridge the tab is a dead end. | Empty state replaces the whole screen, so there's nothing to search. |

## Plan

1. **Variety**: run the combined query plus one query per expiring item, concurrently, capped per query;
   merge round-robin; drop near-duplicate titles; clean "Recipe 5"-style suffixes.
2. **Search**: a search field (Edamam free-text) with quick ideas; combines with selected ingredients.
3. **Cook with**: a chip row of fridge ingredients (expiring ones marked). Pick any to search around them;
   none picked = "what expires first" (today's behaviour).
4. **Filters**: quick chips (meal, time, vegetarian, high protein, few missing) plus a Filters sheet for meal,
   dish type, cuisine, diet (vegetarian, vegan, pescatarian, keto, gluten-free, dairy-free, high protein, low carb,
   low fat), max time and max missing ingredients. Sent to Edamam as `mealType` / `dishType` / `cuisineType` /
   `health` / `diet` / `time`, and enforced client-side (mock + cached results).
5. **Sort**: best match (default), quickest, fewest missing, fewest calories.
6. **Compact cards**: "Uses" names only (expiring ones highlighted), one-line missing list or "You have everything",
   time + kcal/serving, non-truncating chip, saved heart. Failed images fall back to an icon.
7. **Recipe detail**: image, time / calories / servings, tags, what it uses from your fridge (with expiry),
   ingredient list marked have / pantry / missing, "Add missing to shopping list", save, share, open full recipe.
8. **Saved recipes**: heart from the card (swipe / long-press) or detail; a "Saved" scope on the tab (stored on this device).
9. **Cache**: per-query cache keyed by filters, 50-minute freshness so images don't expire; stale cache still used offline.
10. **Empty states**: search and filters stay visible; "No matches" offers "Clear filters".
11. **Mock data**: tag the sample recipes and add more variety so filters and search work offline.
12. **Tests**: near-duplicate merging, title cleanup, filter matching, query building.
