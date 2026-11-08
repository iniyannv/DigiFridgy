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
from . import barcode, pending

log = logging.getLogger("photo")

PHOTO_OFF = ("📸 I couldn't find a barcode in that photo. Get close so the barcode fills the frame, in good "
             "light. Receipt and fridge photos need photo reading set up on this server (LLM_API_KEY); "
             "until then, scan the receipt in the app.")
NO_READER = ("📸 I can read receipt and fridge photos once photo reading is set up on this server "
             "(LLM_API_KEY). Until then, text USED / ADD, or scan the receipt in the app.")


def render(kind: str, items: list[dict], skipped: list[str] | None = None) -> str:
    head = {"receipt": "🧾 From your receipt:", "barcode": "🏷️ Scanned:"}.get(kind, "📸 I can see:")
    lines = [head]
    for i, it in enumerate(items, 1):
        qty = f" ×{it['qty']}" if it["qty"] > 1 else ""
        price = f" ${it['total']:,.2f}" if it.get("total") else ""
        seen = f" ({it['label']})" if it.get("label") else ""
        lines.append(f"{i}) {it['emoji']} {it['name']}{qty}{price}{seen}")
    if skipped:
        lines.append(f"(Not added: {', '.join(skipped[:4])}{' …' if len(skipped) > 4 else ''})")
    n = len(items)
    lines.append(f"Add {'it' if n == 1 else f'these {n}'}? Reply YES to add {'it' if n == 1 else 'all'}"
                 + (", or a number to drop one." if n > 1 else ", or NO."))
    return "\n".join(lines)


async def handle(ctx: Ctx, hh: Household, m: Inbound) -> str:
    has_reader = ctx.llm is not None and hasattr(ctx.llm, "read_items")
    if not has_reader and not barcode.available():
        return NO_READER
    try:
        meta = await ctx.photon.get_attachment(m.attachment_id)
        ctype = (meta.get("contentType") or "").lower()
        if not ctype.startswith("image/"):
            return "📎 I can read photos of a grocery receipt or your fridge. Send one of those?"
        data = await ctx.photon.download_attachment(m.attachment_id)
    except Exception:
        log.exception("couldn't fetch attachment %s", m.attachment_id)
        return "📸 I couldn't open that photo. Try sending it again?"
    codes = await barcode.decode(data)
    if codes:
        reply = await _from_barcodes(ctx, hh, codes, fall_through=has_reader)
        if reply:
            return reply
    if not has_reader:
        return PHOTO_OFF
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


async def _from_barcodes(ctx: Ctx, hh: Household, codes: list[str], fall_through: bool) -> str | None:
    """Ask to add the scanned products. None means no product was found and the LLM reader should try."""
    found: dict[str, dict] = {}
    skipped: list[str] = []
    unknown: list[str] = []
    for code in codes[:5]:
        product = await barcode.lookup_product(code)
        if product is None:
            unknown.append(code)
            continue
        label = barcode.product_label(product) or code
        info = barcode.catalog_match(product)
        if info is None:
            skipped.append(label)
            continue
        row = found.setdefault(info.sku, {"sku": info.sku, "name": info.display_name, "emoji": info.emoji,
                                          "qty": 0, "total": 0.0, "label": label})
        row["qty"] += 1
    items = list(found.values())
    if not items:
        if skipped:
            it = "It isn't" if len(skipped) == 1 else "They aren't"
            return f"🏷️ That's {', '.join(skipped[:3])}. {it} something I track yet, so I didn't add it."
        if fall_through:
            return None
        return (f"🏷️ I read barcode {unknown[0]}, but I couldn't find that product. "
                "Try scanning it in the app, or send a photo of the receipt.")
    with Session(ctx.engine) as s:
        pending.create(s, hh.id, "photo_stock", {"kind": "barcode", "items": items, "skipped": skipped},
                       ctx.clock.now(), minutes=6 * 60)
        s.commit()
    return render("barcode", items, skipped)


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
