"""Approximate shelf lives by SKU (see shelf_life.json)."""
from __future__ import annotations

import json
from dataclasses import dataclass, field
from functools import lru_cache
from pathlib import Path

PATH = Path(__file__).with_name("shelf_life.json")

# Words a person might use for a whole category ("finished the veggies").
CATEGORY_WORDS = {
    "produce": "produce", "fruit": "produce", "fruits": "produce", "veggies": "produce",
    "vegetables": "produce", "veg": "produce",
    "dairy": "dairy",
    "meat": "meat", "meats": "meat",
    "deli": "deli",
    "bakery": "bakery", "baked goods": "bakery",
    "frozen": "frozen", "frozen stuff": "frozen", "frozen food": "frozen",
    "leftovers": "leftovers",
}


@dataclass(frozen=True)
class ShelfInfo:
    sku: str
    display_name: str
    category: str
    location: str
    shelf_life_days: int
    emoji: str
    synonyms: tuple[str, ...] = field(default_factory=tuple)
    staple: bool = False


@lru_cache
def table() -> dict[str, ShelfInfo]:
    data = json.loads(PATH.read_text())
    out = {}
    for row in data["items"]:
        out[row["sku"]] = ShelfInfo(
            sku=row["sku"], display_name=row["display_name"], category=row["category"],
            location=row["location"], shelf_life_days=int(row["shelf_life_days"]), emoji=row["emoji"],
            synonyms=tuple(row.get("synonyms", [])), staple=bool(row.get("staple", False)),
        )
    return out


@lru_cache
def _other() -> dict:
    return json.loads(PATH.read_text())["other"]


def lookup(sku: str) -> ShelfInfo:
    """Known SKU, or an `other` entry with a 7-day default."""
    info = table().get(sku)
    if info:
        return info
    o = _other()
    name = sku.replace("_", " ").strip() or "item"
    return ShelfInfo(sku=sku, display_name=name, category=o["category"], location=o["location"],
                     shelf_life_days=int(o["shelf_life_days"]), emoji=o["emoji"], synonyms=(name,))


def is_known(sku: str) -> bool:
    return sku in table()


def staples() -> list[ShelfInfo]:
    return [i for i in table().values() if i.staple]


def find_by_words(text: str) -> ShelfInfo | None:
    """Best SKU for a free-text name ("eggs", "oj"), or None."""
    from .matching import best_catalog_match
    return best_catalog_match(text)
