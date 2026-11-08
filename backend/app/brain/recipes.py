"""Recipes over text: what the fridge can make, soonest-expiring food first.

Scoring follows the iPhone app's RecipeScorer: +3 for each ingredient you have that expires within
3 days, +1 for each other ingredient you have, -1 for each one you'd need to buy. Pantry basics
(salt, oil, ...) never count as missing. The optional LLM can write recipes for what's in the fridge;
the templates in recipes.json always work without it.

Flow: RECIPES (or "what can I make with the spinach?") lists up to 3 numbered recipes. Replying
with a number shows that recipe's ingredients, marks what's missing and offers to put the missing
ones on the shopping list (a YES/NO question like any other).
"""
from __future__ import annotations

import json
import logging
import re
from dataclasses import dataclass, field
from pathlib import Path

from sqlmodel import Session

from ..context import Ctx
from ..fridge import inventory
from ..fridge.matching import THRESHOLD, best_catalog_match, category_for, clean, match_items, score
from ..fridge.shelf_life import lookup
from ..models import Item
from . import copy, pending

log = logging.getLogger("recipes")

SOON_DAYS = 3
SHOW = 3
TTL_MINUTES = 120  # people reply with a number a while later, while they're cooking

STAPLES = {"salt", "pepper", "black pepper", "water", "oil", "olive oil", "vegetable oil", "canola oil",
           "sugar", "flour", "all-purpose flour", "ice", "cooking spray", "kosher salt", "sea salt",
           "butter or oil", "spices", "seasoning", "salt and pepper"}

# "what can I make with what I have?" is a plain RECIPES, not a search for an ingredient.
NO_FOCUS = {"what i have", "what we have", "what's in my fridge", "whats in my fridge", "my fridge", "the fridge",
            "fridge", "this", "that", "it", "them", "stuff", "my stuff", "what's left", "whats left",
            "what i've got", "what ive got", "everything", "my food",
            "easy", "quick", "simple", "healthy", "good", "cheap", "dinner", "lunch", "breakfast", "new", "any",
            "some", "tonight", "today", "leftover", "food"}


# "what can I make with what's expiring?", "use up the stuff going bad", "expiring recipes": only recipes
# that use something from the ⏰ Use soon list (the same items EXPIRING shows).
_EXPIRING = re.compile(r"\b(expir\w*|about to (go|expire|spoil|turn)|go(es|ing)? (bad|off)|spoil\w*"
                       r"|use[ -]soon|before (it|they) (go|goes|spoil)|old(est)? (stuff|food))\b")


def wants_expiring(query: str | None) -> bool:
    return bool(query) and bool(_EXPIRING.search(query.lower()))


# ---------- difficulty, and "easy" / "quick" / "under 30 min" asks ----------

LEVELS = ("easy", "medium", "hard")


def difficulty(minutes: float | None, ingredients: int) -> str:
    """Same rule as the app's RecipeDifficulty: how long it takes plus how many ingredients."""
    t = 1 if minutes is None else 0 if minutes <= 20 else 1 if minutes <= 45 else 2
    i = 0 if ingredients <= 6 else 1 if ingredients <= 11 else 2
    return LEVELS[min(2, max(0, t + i - 1))]


def level_of(recipe: dict) -> str:
    return difficulty(recipe.get("minutes"), len(recipe["ingredients"]) + len(recipe.get("extras", [])))


def meta(recipe: dict) -> str | None:
    """"15 min · easy" for recipes we know the time of."""
    return f"{recipe['minutes']} min · {level_of(recipe)}" if recipe.get("minutes") else None


@dataclass
class Wants:
    max_minutes: int | None = None
    easy: bool = False
    rest: str | None = None      # what's left to search for ("chicken")
    what: str = "recipes"         # "easy recipes", "recipes under 30 min"

    @property
    def active(self) -> bool:
        return self.easy or self.max_minutes is not None

    def fits(self, recipe: dict) -> bool:
        if self.max_minutes is not None and not (recipe.get("minutes") and recipe["minutes"] <= self.max_minutes):
            return False
        return not self.easy or level_of(recipe) == "easy"


QUICK_MINUTES = 20
_UNDER = re.compile(r"\b(?:under|in|within|less than|in less than|in under)\s*(\d{1,3})\s*(?:min|mins|minutes|m)\b")
_EASY = re.compile(r"\b(easy|easiest|simple|simplest|beginner|no[- ]fuss|lazy|low[- ]effort)\b")
_QUICK = re.compile(r"\b(quick|quickest|fast|fastest|speedy)\b")
_FILLER_WORDS = re.compile(r"^(?:(?:an?|some|any|the|my)\s+)*(?:(?:recipes?|recipe ideas|ideas|meals?|dinners?|lunch|breakfast"
                           r"|dishes|something|to (?:make|cook)|what (?:can|could|should) (?:i|we) (?:make|cook))\s*)*"
                           r"(?:(?:with|using|for|from|that uses?|to use up)\s+)?")


def wants_of(query: str | None) -> Wants:
    q = (query or "").lower().strip()
    w = Wants()
    if m := _UNDER.search(q):
        w.max_minutes = max(1, int(m.group(1)))
        q = q[:m.start()] + q[m.end():]
    quick = bool(_QUICK.search(q))
    if quick:
        w.max_minutes = min(w.max_minutes or QUICK_MINUTES, QUICK_MINUTES)
    w.easy = bool(_EASY.search(q))
    q = _QUICK.sub(" ", _EASY.sub(" ", q))
    q = re.sub(r"\s+", " ", q).strip(" ,")
    q = _FILLER_WORDS.sub("", q).strip(" ,")
    w.rest = q or None
    adj = [a for a, on in (("easy", w.easy), ("quick", quick)) if on]
    w.what = " ".join(adj + ["recipes"]) + (f" under {w.max_minutes} min" if w.max_minutes and not quick else "")
    return w


def _templates() -> list[dict]:
    raw = json.loads(Path(__file__).with_name("recipes.json").read_text())
    out = []
    for r in raw:
        ings = [{"name": lookup(sku).display_name, "sku": sku} for sku in r["uses"]]
        out.append({"name": r["name"], "ingredients": ings, "extras": list(r.get("extras", [])),
                    "minutes": r.get("minutes")})
    return out


TEMPLATES = _templates()


@dataclass
class Focus:
    label: str                      # what they typed, cleaned ("spinach")
    sku: str | None = None          # the catalog item it names
    category: str | None = None     # "veggies" -> produce


@dataclass
class Scored:
    recipe: dict
    score: int
    have: list[tuple[dict, Item]] = field(default_factory=list)
    missing: list[dict] = field(default_factory=list)


def focus_of(query: str | None) -> Focus | None:
    q = clean(query or "")
    if not q or q in NO_FOCUS or (query or "").strip().lower() in NO_FOCUS:
        return None
    cat = category_for(q)
    if cat:
        return Focus(label=q, category=cat)
    info = best_catalog_match(q)
    return Focus(label=q, sku=info.sku if info else None)


def _is_staple(ing: dict) -> bool:
    return ing["name"].strip().lower() in STAPLES


def _ing_matches(ing: dict, sku: str | None, name: str) -> bool:
    if sku and ing.get("sku") == sku:
        return True
    return score(ing["name"], sku or "", name) >= THRESHOLD


def includes(recipe: dict, focus: Focus) -> bool:
    for ing in recipe["ingredients"]:
        if focus.category:
            if ing.get("sku") and lookup(ing["sku"]).category == focus.category:
                return True
        elif _ing_matches(ing, focus.sku, focus.label) or score(focus.label, ing.get("sku") or "", ing["name"]) >= 90:
            return True
    return False


def _have(ing: dict, fresh: list[Item]) -> Item | None:
    """The soonest-expiring fridge item that covers this ingredient (fresh is sorted by expiry)."""
    if ing.get("sku"):
        for i in fresh:
            if i.sku == ing["sku"]:
                return i
    cands = match_items(ing["name"], fresh)
    if cands:
        ids = set(cands[0].ids)
        return next(i for i in fresh if i.id in ids)
    return None


def days_left(item: Item, clock) -> int:
    return (clock.to_local(item.expires_at).date() - clock.today()).days


def score_recipe(recipe: dict, fresh: list[Item], clock) -> Scored:
    out = Scored(recipe=recipe, score=0)
    used: set[str] = set()
    for ing in recipe["ingredients"]:
        if _is_staple(ing):
            continue
        item = _have(ing, fresh)
        if item is not None:
            if item.sku in used:
                continue
            used.add(item.sku)
            out.score += 3 if days_left(item, clock) <= SOON_DAYS else 1
            out.have.append((ing, item))
        elif not any(m["name"].lower() == ing["name"].lower() for m in out.missing):
            out.score -= 1
            out.missing.append(ing)
    out.have.sort(key=lambda p: p[1].expires_at)
    return out


def rank(recipes: list[dict], fresh: list[Item], clock, focus: Focus | None = None,
         wants: Wants | None = None) -> list[Scored]:
    pool = [r for r in recipes if (focus is None or includes(r, focus)) and (wants is None or wants.fits(r))]
    scored = [score_recipe(r, fresh, clock) for r in pool]
    if focus is None:
        scored = [x for x in scored if x.have]
    scored.sort(key=lambda x: (-x.score, len(x.missing), x.recipe["name"]))
    return scored


def from_llm(raw: list[dict]) -> list[dict]:
    """LLM recipes -> the template shape. Ingredients are matched to catalog items where possible."""
    out = []
    for r in raw:
        ings = []
        for name in r.get("ingredients", []):
            info = best_catalog_match(name)
            ings.append({"name": name.lower(), "sku": info.sku if info else None})
        if r.get("name") and len(ings) >= 2:
            out.append({"name": r["name"], "ingredients": ings, "extras": []})
    return out


def _focus_in_fridge(focus: Focus, fresh: list[Item]) -> bool:
    if focus.category:
        return any(i.category == focus.category for i in fresh)
    return any((focus.sku and i.sku == focus.sku) for i in fresh) or bool(match_items(focus.label, fresh))


async def suggest(ctx: Ctx, household_id: int, query: str | None = None) -> str:
    """Up to 3 numbered recipes; remembers them so a number reply can show one."""
    wants = wants_of(query)
    if wants_expiring(query):
        return await suggest_expiring(ctx, household_id, wants)
    focus = focus_of(wants.rest if wants.active else query)
    with Session(ctx.engine) as s:
        fresh = inventory.fresh_items(s, household_id)
    if not fresh:
        return copy.recipes_empty()
    fresh = [i for i in fresh if days_left(i, ctx.clock) >= 0] or fresh

    have_focus = focus is None or _focus_in_fridge(focus, fresh)
    picks: list[Scored] = []
    # LLM recipes don't come with a time, so "easy" / "quick" asks use the templates.
    if ctx.llm is not None and hasattr(ctx.llm, "recipes") and not wants.active:
        soon = [i.name for i in fresh if days_left(i, ctx.clock) <= SOON_DAYS]
        try:
            raw = await ctx.llm.recipes(list(dict.fromkeys(soon)), sorted({i.name for i in fresh}),
                                        focus.label if focus else None)
        except Exception:
            log.exception("llm recipes failed")
            raw = None
        if raw:
            picks = rank(from_llm(raw), fresh, ctx.clock, None)
    if not picks:
        picks = rank(TEMPLATES, fresh, ctx.clock, focus, wants)
    no_recipe_for = None
    if not picks and focus is not None:
        no_recipe_for = focus.label
        focus = None
        picks = rank(TEMPLATES, fresh, ctx.clock, None, wants)
    if not picks and wants.active:
        # Nothing that easy or quick: say so, then the usual suggestions.
        no_recipe_for, focus = None, None
        picks = rank(TEMPLATES, fresh, ctx.clock, None)
        if picks:
            return copy.recipes_list(_remember(ctx, household_id, picks[:SHOW]), none_fit=wants.what)
    if not picks:
        return copy.recipes_none()

    rows = _remember(ctx, household_id, picks[:SHOW])
    return copy.recipes_list(rows, focus=focus.label if focus else None, have_focus=have_focus,
                             no_recipe_for=no_recipe_for, what=wants.what if wants.active else None)


def _remember(ctx: Ctx, household_id: int, picks: list[Scored]) -> list:
    """Saves the shown recipes so a number reply can open one; returns the rows for the list text."""
    with Session(ctx.engine) as s:
        pending.create(s, household_id, "recipes", {"recipes": [p.recipe for p in picks]}, ctx.clock.now(),
                       minutes=TTL_MINUTES)
        s.commit()
    return [(p.recipe["name"], [(i.name, copy.day_label(i.expires_at, ctx.clock)) for _, i in p.have],
             [m["name"] for m in p.missing], meta(p.recipe)) for p in picks]


def rank_expiring(recipes: list[dict], fresh: list[Item], soon_ids: set[int], clock,
                  wants: Wants | None = None) -> list[Scored]:
    """Only recipes that use at least one about-to-expire item; the ones that use the most come first."""
    out = []
    for p in rank(recipes, fresh, clock, None, wants):
        n = sum(1 for _, i in p.have if i.id in soon_ids)
        if n:
            out.append((n, p))
    out.sort(key=lambda x: (-x[0], -x[1].score, len(x[1].missing), x[1].recipe["name"]))
    return [p for _, p in out]


async def suggest_expiring(ctx: Ctx, household_id: int, wants: Wants | None = None) -> str:
    """Recipes that use what's about to expire (the ⏰ Use soon items)."""
    with Session(ctx.engine) as s:
        fresh = inventory.fresh_items(s, household_id)
        soon = inventory.use_soon(s, household_id, ctx.clock.now())
    fresh = [i for i in fresh if days_left(i, ctx.clock) >= 0]
    soon = [i for i in soon if days_left(i, ctx.clock) >= 0]
    if not fresh:
        return copy.recipes_empty()
    if not soon:
        rows = _remember(ctx, household_id, rank(TEMPLATES, fresh, ctx.clock)[:SHOW])
        return copy.recipes_expiring([], rows) if rows else copy.recipes_none()
    expiring = list(dict.fromkeys((i.name, copy.day_label(i.expires_at, ctx.clock)) for i in soon))
    soon_ids = {i.id for i in soon}
    wants = wants if wants is not None and wants.active else None
    picks: list[Scored] = []
    if ctx.llm is not None and hasattr(ctx.llm, "recipes") and wants is None:
        try:
            raw = await ctx.llm.recipes([n for n, _ in expiring], sorted({i.name for i in fresh}), None)
        except Exception:
            log.exception("llm recipes failed")
            raw = None
        if raw:
            picks = rank_expiring(from_llm(raw), fresh, soon_ids, ctx.clock)
    if not picks:
        picks = rank_expiring(TEMPLATES, fresh, soon_ids, ctx.clock, wants)
    if not picks and wants is not None:
        # None that easy or quick use them: the ones that do, said plainly.
        picks = rank_expiring(TEMPLATES, fresh, soon_ids, ctx.clock)
        if picks:
            return copy.recipes_expiring(expiring, _remember(ctx, household_id, picks[:SHOW]), none_fit=wants.what)
    if not picks:
        rows = _remember(ctx, household_id, rank(TEMPLATES, fresh, ctx.clock)[:SHOW])
        return copy.recipes_expiring(expiring, rows, none_use_them=True) if rows else copy.recipes_none()
    return copy.recipes_expiring(expiring, _remember(ctx, household_id, picks[:SHOW]),
                                 what=wants.what if wants else None)


def _on_list(rows, ing: dict) -> bool:
    return any((ing.get("sku") and r.sku == ing["sku"]) or r.name.lower() == ing["name"].lower()
               for r in rows if r.confirmed)


def detail(ctx: Ctx, s: Session, household_id: int, payload: dict, n: int) -> str:
    """One recipe's ingredients against the fridge right now. Offers to add what's missing."""
    from .commands import _open_rows
    recipes = payload.get("recipes", [])
    if not 1 <= n <= len(recipes):
        return f"Reply a number from 1 to {len(recipes)}." if len(recipes) > 1 else "Reply 1 for that recipe."
    recipe = recipes[n - 1]
    fresh = inventory.fresh_items(s, household_id)
    sc = score_recipe(recipe, fresh, ctx.clock)
    rows = _open_rows(s, household_id)
    to_add = [m for m in sc.missing if not _on_list(rows, m)]
    already = [m["name"] for m in sc.missing if _on_list(rows, m)]
    pantry = [i["name"] for i in recipe["ingredients"] if _is_staple(i)] + list(recipe.get("extras", []))
    if to_add:
        pending.create(s, household_id, "recipe_missing",
                       {"recipe": recipe["name"], "items": to_add}, ctx.clock.now())
    s.commit()
    return copy.recipe_detail(recipe["name"] + (f" ({meta(recipe)})" if meta(recipe) else ""),
                              [(i.name, copy.day_label(i.expires_at, ctx.clock)) for _, i in sc.have],
                              [m["name"] for m in to_add], already, pantry)


def add_missing(ctx: Ctx, s: Session, household_id: int, payload: dict) -> list[str]:
    """YES to "add the missing ones": puts them on the shopping list. Returns what was added."""
    from .commands import add_one
    added = []
    for ing in payload.get("items", []):
        name, new = add_one(ctx, s, household_id, ing["name"], source="recipe", sku=ing.get("sku"))
        if new:
            added.append(name)
    return added


def ingredients_text(ctx: Ctx, household_id: int) -> str:
    with Session(ctx.engine) as s:
        fresh = inventory.fresh_items(s, household_id)
    seen, soon, rest = set(), [], []
    for i in fresh:
        if i.sku in seen:
            continue
        seen.add(i.sku)
        d = days_left(i, ctx.clock)
        if d < 0:
            continue
        (soon if d <= SOON_DAYS else rest).append((i.name, copy.day_label(i.expires_at, ctx.clock)))
    return copy.ingredients(soon, rest)
