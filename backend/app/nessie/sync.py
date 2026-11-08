"""Purchase sync: Nessie grocery purchases -> fridge items -> "Stocked" iMessage."""
from __future__ import annotations

import asyncio
import logging
from datetime import date, datetime, time, timedelta

from sqlalchemy.exc import IntegrityError
from sqlmodel import Session, select

from ..brain import copy
from ..context import Ctx
from ..fridge import inventory
from ..fridge.parse import has_items, parse_description
from ..models import Household, ProcessedPurchase
from ..photon.outbound import notify_household

log = logging.getLogger("sync")

# Purchases older than this are history: stocked silently, no text.
RECENT_DAYS = 1


async def merchant_info(ctx: Ctx, merchant_id: str) -> dict:
    if merchant_id in ctx.merchant_cache:
        return ctx.merchant_cache[merchant_id]
    try:
        m = await ctx.nessie.get_merchant(merchant_id)
    except Exception:
        log.warning("merchant lookup failed for %s", merchant_id)
        m = {"name": "a store", "category": []}
    ctx.merchant_cache[merchant_id] = m
    return m


def is_grocery(merchant: dict) -> bool:
    cat = merchant.get("category")
    cats = cat if isinstance(cat, list) else [cat or ""]
    return any("grocer" in str(c).lower() for c in cats)


def _purchase_date(raw: str | None, fallback: date) -> date:
    try:
        return date.fromisoformat((raw or "")[:10])
    except ValueError:
        return fallback


async def sync_household(ctx: Ctx, hh: Household) -> list[str]:
    """Returns the Nessie IDs of purchases newly processed."""
    if not hh.checking_account_id:
        return []
    purchases = await ctx.nessie.list_purchases(hh.checking_account_id)
    with Session(ctx.engine) as s:
        seen = set(s.exec(select(ProcessedPurchase.nessie_purchase_id)).all())
    new_ids = []
    for p in sorted(purchases, key=lambda x: x.get("purchase_date", "")):
        pid = p.get("_id")
        if not pid or pid in seen:
            continue
        if await process_purchase(ctx, hh, p):
            new_ids.append(pid)
    return new_ids


async def process_purchase(ctx: Ctx, hh: Household, p: dict) -> bool:
    merchant = await merchant_info(ctx, p.get("merchant_id", ""))
    grocery = is_grocery(merchant)
    now = ctx.clock.now()
    today = ctx.clock.today()
    pdate = _purchase_date(p.get("purchase_date"), today)
    recent = pdate >= today - timedelta(days=RECENT_DAYS)
    parsed = parse_description(p.get("description")) if grocery and has_items(p.get("description")) else None
    if parsed and parsed.errors:
        log.warning("purchase %s: skipped malformed lines %s", p["_id"], parsed.errors)

    with Session(ctx.engine) as s:
        record = ProcessedPurchase(
            nessie_purchase_id=p["_id"], household_id=hh.id, merchant_name=merchant.get("name", ""),
            amount=float(p.get("amount") or 0), purchase_date=pdate, is_grocery=grocery,
            item_count=sum(li.qty for li in parsed.items) if parsed else 0, processed_at=now,
        )
        s.add(record)
        try:
            s.flush()  # claims the purchase ID; a concurrent sync loses here
        except IntegrityError:
            s.rollback()
            return False
        items = []
        if parsed and parsed.items:
            # Today's purchase is "now"; older ones are placed mid-day on their date.
            purchased_at = now if pdate >= today else ctx.clock.local_to_utc(datetime.combine(pdate, time(12)))
            items = inventory.stock_items(s, hh.id, parsed.items, purchased_at, p["_id"], now)
        s.commit()
        fresh = [i for i in items if i.status == "fresh"]
        text = copy.stocked(merchant.get("name", "the store"), record.amount, fresh, ctx.clock) if fresh else None

    if text and recent:
        await notify_household(ctx, hh.id, text, f"stock:{p['_id']}")
    return True


async def sync_all(ctx: Ctx) -> int:
    with Session(ctx.engine) as s:
        households = list(s.exec(select(Household).where(Household.checking_account_id != None)))  # noqa: E711
    total = 0
    for hh in households:
        try:
            total += len(await sync_household(ctx, hh))
        except Exception:
            log.exception("sync failed for household %s", hh.id)
    return total


_lock = asyncio.Lock()


async def sync_now(ctx: Ctx) -> int:
    async with _lock:
        return await sync_all(ctx)


async def sync_loop(ctx: Ctx) -> None:
    while True:
        try:
            await sync_now(ctx)
        except Exception:
            log.exception("sync loop error")
        await asyncio.sleep(ctx.settings.sync_interval)
