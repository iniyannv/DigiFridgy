"""Text a photo of a receipt or your fridge: the agent reads it, lists what it found, and the person
decides. "Add these 6? Reply YES to add all, or a number to drop one." Nothing is stocked without a YES.
"""
from __future__ import annotations

import logging

from sqlmodel import Session

from ..context import Ctx
from ..fridge import inventory
from ..fridge.matching import best_catalog_match
from ..fridge.parse import LineItem
from ..models import Household
from ..photon.client import Inbound
from . import pending

log = logging.getLogger("photo")

PHOTO_OFF = ("📸 I can read receipt and fridge photos once photo reading is set up on this server "
             "(LLM_API_KEY). Until then, text USED / ADD, or scan the receipt in the app.")


def render(kind: str, items: list[dict], skipped: list[str] | None = None) -> str:
    head = "🧾 From your receipt:" if kind == "receipt" else "📸 I can see:"
    lines = [head]
    for i, it in enumerate(items, 1):
        qty = f" ×{it['qty']}" if it["qty"] > 1 else ""
        price = f" ${it['total']:,.2f}" if it.get("total") else ""
        lines.append(f"{i}) {it['emoji']} {it['name']}{qty}{price}")
    if skipped:
        lines.append(f"(Not added: {', '.join(skipped[:4])}{' …' if len(skipped) > 4 else ''})")
    n = len(items)
    lines.append(f"Add {'it' if n == 1 else f'these {n}'}? Reply YES to add {'it' if n == 1 else 'all'}"
                 + (", or a number to drop one." if n > 1 else ", or NO."))
    return "\n".join(lines)


async def handle(ctx: Ctx, hh: Household, m: Inbound) -> str:
    if ctx.llm is None or not hasattr(ctx.llm, "read_items"):
        return PHOTO_OFF
    try:
        meta = await ctx.photon.get_attachment(m.attachment_id)
        ctype = (meta.get("contentType") or "").lower()
        if not ctype.startswith("image/"):
            return "📎 I can read photos of a grocery receipt or your fridge. Send one of those?"
        data = await ctx.photon.download_attachment(m.attachment_id)
    except Exception:
        log.exception("couldn't fetch attachment %s", m.attachment_id)
        return "📸 I couldn't open that photo. Try sending it again?"
    result = await ctx.llm.read_items(data, ctype)
    if not result or not result.get("items"):
        return "📸 I couldn't find groceries in that photo. A straight-on shot in good light works best."
    kind = "receipt" if result["kind"] == "receipt" else "food"
    with Session(ctx.engine) as s:
        have = {i.sku for i in inventory.fresh_items(s, hh.id)}
    found: dict[str, dict] = {}
    skipped: list[str] = []
    for it in result["items"]:
        info = best_catalog_match(it["name"])
        if info is None:
            skipped.append(it["name"])
            continue
        if kind == "food" and info.sku in have:
            skipped.append(f"{info.display_name} (already tracked)")
            continue
        row = found.setdefault(info.sku, {"sku": info.sku, "name": info.display_name, "emoji": info.emoji,
                                          "qty": 0, "total": 0.0})
        row["qty"] += it["qty"]
        if it.get("price") is not None:
            row["total"] = round(row["total"] + float(it["price"]), 2)
    items = list(found.values())
    if not items:
        return "📸 Nothing new to add from that photo." + (f" (Saw: {', '.join(skipped[:4])})" if skipped else "")
    with Session(ctx.engine) as s:
        pending.create(s, hh.id, "photo_stock", {"kind": kind, "items": items, "skipped": skipped},
                       ctx.clock.now(), minutes=6 * 60)
        s.commit()
    return render(kind, items, skipped)


def drop(payload: dict, n: int) -> tuple[dict, str | None]:
    items = payload["items"]
    if not 1 <= n <= len(items):
        return payload, None
    gone = items[n - 1]["name"]
    return {**payload, "items": items[:n - 1] + items[n:]}, gone


def stock(ctx: Ctx, s: Session, hh: Household, payload: dict) -> list:
    now = ctx.clock.now()
    lines = [LineItem(sku=i["sku"], qty=i["qty"], total=i.get("total") or 0.0) for i in payload["items"]]
    return inventory.stock_items(s, hh.id, lines, now, None, now)
