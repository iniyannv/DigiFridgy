"""Match what a person typed ("the milk") to items, list rows, or catalog SKUs."""
from __future__ import annotations

import re
from dataclasses import dataclass

from rapidfuzz import fuzz

from .shelf_life import CATEGORY_WORDS, ShelfInfo, lookup, table

THRESHOLD = 82
_FILLER = re.compile(r"\b(the|my|our|a|an|some|all|of|last|rest|remaining|that|those|these)\b")


def clean(text: str) -> str:
    t = text.lower().strip()
    t = re.sub(r"[^\w%\s'-]", " ", t)
    t = _FILLER.sub(" ", t)
    return re.sub(r"\s+", " ", t).strip()


def _names_for(sku: str, name: str) -> list[str]:
    info = lookup(sku)
    names = {name.lower(), info.display_name.lower(), sku.replace("_", " ")}
    names.update(s.lower() for s in info.synonyms)
    return [n for n in names if n]


def score(query: str, sku: str, name: str) -> float:
    q = clean(query)
    if not q:
        return 0.0
    best = 0.0
    for n in _names_for(sku, name):
        if q == n:
            return 100.0
        # Plural/singular tolerance and whole-word containment.
        if q.rstrip("s") == n.rstrip("s"):
            best = max(best, 98.0)
        elif re.search(rf"\b{re.escape(q)}\b", n) or re.search(rf"\b{re.escape(n)}\b", q):
            best = max(best, 90.0)
        else:
            best = max(best, float(fuzz.ratio(q, n)))
    return best


@dataclass
class Candidate:
    sku: str
    name: str
    score: float
    ids: list[int]


def match_items(query: str, items: list) -> list[Candidate]:
    """Groups matching items by SKU (best first). More than one group = ambiguous.

    `items` are rows with .id, .sku, .name (fresh items or list rows).
    """
    groups: dict[str, Candidate] = {}
    for it in items:
        s = score(query, it.sku or "", it.name)
        if s < THRESHOLD:
            continue
        key = it.sku or it.name.lower()
        g = groups.get(key)
        if g is None:
            groups[key] = Candidate(sku=key, name=it.name, score=s, ids=[it.id])
        else:
            g.ids.append(it.id)
            g.score = max(g.score, s)
    ranked = sorted(groups.values(), key=lambda c: -c.score)
    if not ranked:
        return []
    top = ranked[0].score
    # An exact hit beats near misses; otherwise keep everything close to the top.
    return [c for c in ranked if c.score >= top - (0 if top >= 98 else 6)]


def category_for(query: str) -> str | None:
    q = clean(query)
    return CATEGORY_WORDS.get(q)


def best_catalog_match(query: str) -> ShelfInfo | None:
    best, best_score = None, 0.0
    for info in table().values():
        s = score(query, info.sku, info.display_name)
        if s > best_score:
            best, best_score = info, s
    return best if best_score >= THRESHOLD else None
