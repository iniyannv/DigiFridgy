"""AI help naming and categorizing scanned products.

Barcode lookups (Open Food Facts) give label names like "Cup Noodles Chicken Flavor 2.25oz", and keyword
matching on that puts it in "chicken" (2-day shelf life). One small LLM call returns a short everyday name
and the category the product actually is, chosen from the caller's own list, so the answer always maps to a
real category. Every answer is checked; with no LLM key, or any failure, callers keep their keyword match.
"""
from __future__ import annotations

import logging
import re
from collections import OrderedDict
from dataclasses import dataclass

from ..context import Ctx

log = logging.getLogger("product_ai")

STORAGE = ("fridge", "freezer", "pantry")
_CACHE: "OrderedDict[tuple, Guess]" = OrderedDict()
_CACHE_SIZE = 500


@dataclass(frozen=True)
class Guess:
    name: str
    category: str
    storage: str


def available(ctx: Ctx) -> bool:
    return ctx.llm is not None and hasattr(ctx.llm, "describe_product")


def _clean_name(raw: object, fallback: str) -> str:
    name = re.sub(r"\s+", " ", str(raw or "")).strip(" .,-")
    if not name or len(name) > 40 or not re.search(r"[A-Za-z]", name):
        return fallback
    return name[0].upper() + name[1:]


async def describe(ctx: Ctx, name: str, brand: str | None, categories: list[str]) -> Guess | None:
    """Name and category for a scanned product, or None (no LLM, bad answer, or nothing to go on)."""
    name = (name or "").strip()
    cats = [c for c in dict.fromkeys(c.strip() for c in categories if isinstance(c, str)) if c][:80]
    if not available(ctx) or not name or not cats:
        return None
    if "other" not in cats:
        cats.append("other")
    key = (name.lower(), (brand or "").lower(), tuple(sorted(cats)))
    if key in _CACHE:
        _CACHE.move_to_end(key)
        return _CACHE[key]
    try:
        data = await ctx.llm.describe_product(name, brand, cats)
    except Exception:
        log.exception("product description failed")
        return None
    if not isinstance(data, dict) or data.get("category") not in cats:
        return None
    storage = data.get("storage") if data.get("storage") in STORAGE else "fridge"
    guess = Guess(name=_clean_name(data.get("name"), name[:40]), category=data["category"], storage=storage)
    _CACHE[key] = guess
    if len(_CACHE) > _CACHE_SIZE:
        _CACHE.popitem(last=False)
    return guess
