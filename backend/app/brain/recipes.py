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
            "what's expiring", "whats expiring", "what i've got", "what ive got", "everything", "my food",
            "easy", "quick", "simple", "healthy", "good", "cheap", "dinner", "lunch", "breakfast", "new", "any",
            "some", "tonight", "today", "leftover", "food"}


def _templates() -> list[dict]:
    raw = json.loads(Path(__file__).with_name("recipes.json").read_text())
    out = []
    for r in raw:
        ings = [{"name": lookup(sku).display_name, "sku": sku} for sku in r["uses"]]
        out.append({"name": r["name"], "ingredients": ings, "extras": list(r.get("extras", []))})
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


def rank(recipes: list[dict], fresh: list[Item], clock, focus: Focus | None = None) -> list[Scored]:
    pool = [r for r in recipes if focus is None or includes(r, focus)]
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
    focus = focus_of(query)
    with Session(ctx.engine) as s:
        fresh = inventory.fresh_items(s, household_id)
    if not fresh:
        return copy.recipes_empty()
    fresh = [i for i in fresh if days_left(i, ctx.clock) >= 0] or fresh

    have_focus = focus is None or _focus_in_fridge(focus, fresh)
    picks: list[Scored] = []
    if ctx.llm is not None and hasattr(ctx.llm, "recipes"):
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
        picks = rank(TEMPLATES, fresh, ctx.clock, focus)
    no_recipe_for = None
    if not picks and focus is not None:
        no_recipe_for = focus.label
        focus = None
        picks = rank(TEMPLATES, fresh, ctx.clock, None)
    if not picks:
        return copy.recipes_none()

    picks = picks[:SHOW]
    with Session(ctx.engine) as s:
        pending.create(s, household_id, "recipes", {"recipes": [p.recipe for p in picks]}, ctx.clock.now(),
                       minutes=TTL_MINUTES)
        s.commit()
    rows = [(p.recipe["name"], [(i.name, copy.day_label(i.expires_at, ctx.clock)) for _, i in p.have],
             [m["name"] for m in p.missing]) for p in picks]
    return copy.recipes_list(rows, focus=focus.label if focus else None, have_focus=have_focus,
                             no_recipe_for=no_recipe_for)


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
    return copy.recipe_detail(recipe["name"],
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
