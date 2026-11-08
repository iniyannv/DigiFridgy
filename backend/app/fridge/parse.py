"""Parser for simulated line items stored in a Nessie purchase description.

Format (strict):
    DIGIFRIDGEY_ITEMS v1 | milk_whole_1gal x1 3.49 | spinach_5oz x2 5.98

Each segment is `<sku> x<qty> <line total>`. The line total covers all units.
Banks don't get line items today; this simulates itemized merchant data.
"""
from __future__ import annotations

import re
from dataclasses import dataclass

HEADER = "DIGIFRIDGEY_ITEMS v1"
_LINE = re.compile(r"^(?P<sku>[a-z0-9_]+)\s+x(?P<qty>\d{1,3})\s+(?P<total>\d+(?:\.\d{1,2})?)$")


@dataclass(frozen=True)
class LineItem:
    sku: str
    qty: int
    total: float

    @property
    def unit_price(self) -> float:
        return round(self.total / self.qty, 2) if self.qty else 0.0


@dataclass
class ParseResult:
    items: list[LineItem]
    errors: list[str]


def has_items(description: str | None) -> bool:
    return bool(description) and description.strip().startswith(HEADER)


def parse_description(description: str | None) -> ParseResult:
    """Returns parsed lines plus a list of malformed segments (skipped, never guessed)."""
    if not has_items(description):
        return ParseResult(items=[], errors=[])
    segments = [s.strip() for s in description.strip().split("|")]
    if segments[0] != HEADER:
        return ParseResult(items=[], errors=[f"bad header: {segments[0]!r}"])
    items, errors = [], []
    for seg in segments[1:]:
        if not seg:
            continue
        m = _LINE.match(seg)
        if not m or int(m["qty"]) == 0:
            errors.append(seg)
            continue
        items.append(LineItem(sku=m["sku"], qty=int(m["qty"]), total=float(m["total"])))
    return ParseResult(items=items, errors=errors)


def build_description(lines: list[tuple[str, int, float]]) -> str:
    """Inverse of parse_description, used by the demo to create purchases."""
    parts = [HEADER] + [f"{sku} x{qty} {total:.2f}" for sku, qty, total in lines]
    return " | ".join(parts)
