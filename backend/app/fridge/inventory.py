"""Inventory rules: stocking, use-soon, used/tossed, expiry -> waste ledger, staples."""
from __future__ import annotations

from datetime import datetime, timedelta

from sqlmodel import Session, select

from ..clock import Clock
from ..models import Item, ShoppingListItem, WasteEntry
from .parse import LineItem
from .shelf_life import lookup, staples

USE_SOON_DAYS = 2


def stock_items(s: Session, household_id: int, lines: list[LineItem], purchased_at: datetime,
                purchase_id: str, now: datetime) -> list[Item]:
    """One row per unit. Items from an old purchase that would already be past
    expiry are recorded as used (we assume they were eaten), not as waste."""
    created = []
    for line in lines:
        info = lookup(line.sku)
        expires = purchased_at + timedelta(days=info.shelf_life_days)
        for _ in range(line.qty):
            already_gone = expires <= now
            item = Item(
                household_id=household_id, sku=line.sku, name=info.display_name, category=info.category,
                location=info.location, emoji=info.emoji, price=line.unit_price, purchased_at=purchased_at,
                expires_at=expires, status="used" if already_gone else "fresh",
                status_at=expires if already_gone else None, source_purchase_id=purchase_id,
            )
            s.add(item)
            created.append(item)
    s.flush()
    return created


def fresh_items(s: Session, household_id: int) -> list[Item]:
    return list(s.exec(select(Item).where(Item.household_id == household_id, Item.status == "fresh")
                       .order_by(Item.expires_at)))


def use_soon(s: Session, household_id: int, now: datetime) -> list[Item]:
    cutoff = now + timedelta(days=USE_SOON_DAYS)
    return [i for i in fresh_items(s, household_id) if i.expires_at <= cutoff]


def mark(s: Session, items: list[Item], status: str, now: datetime) -> float:
    """Marks items used/tossed. Tossed items go on the waste ledger. Returns wasted $."""
    wasted = 0.0
    for it in items:
        it.status = status
        it.status_at = now
        s.add(it)
        if status == "tossed":
            wasted += record_waste(s, it, "tossed", now)
    s.flush()
    return round(wasted, 2)


def record_waste(s: Session, item: Item, reason: str, now: datetime) -> float:
    if s.exec(select(WasteEntry).where(WasteEntry.item_id == item.id)).first():
        return 0.0
    s.add(WasteEntry(household_id=item.household_id, item_id=item.id, item_name=item.name,
                     amount=item.price, reason=reason, recorded_at=now))
    return item.price


def expire_due(s: Session, household_id: int, now: datetime) -> list[Item]:
    """Fresh items past expiry become `expired` and their price is recorded as waste."""
    due = list(s.exec(select(Item).where(Item.household_id == household_id, Item.status == "fresh",
                                         Item.expires_at <= now)))
    for it in due:
        it.status = "expired"
        it.status_at = now
        s.add(it)
        record_waste(s, it, "expired", now)
    s.flush()
    return due


def waste_between(s: Session, household_id: int, start: datetime, end: datetime) -> list[WasteEntry]:
    return list(s.exec(select(WasteEntry).where(WasteEntry.household_id == household_id,
                                                WasteEntry.recorded_at >= start,
                                                WasteEntry.recorded_at < end)))


def week_bounds(clock: Clock) -> tuple[datetime, datetime]:
    start_local = datetime.combine(clock.week_start(), datetime.min.time())
    start = clock.local_to_utc(start_local)
    return start, start + timedelta(days=7)


def month_bounds(clock: Clock) -> tuple[datetime, datetime]:
    today = clock.today()
    start_local = datetime(today.year, today.month, 1)
    nxt = datetime(today.year + (today.month == 12), today.month % 12 + 1, 1)
    return clock.local_to_utc(start_local), clock.local_to_utc(nxt)


def suggest_staples(s: Session, household_id: int, now: datetime,
                    only: set[str] | None = None) -> list[ShoppingListItem]:
    """Staples that were bought before but have no fresh unit left become
    unconfirmed suggestions (the user confirms with ADD ALL). `only` limits the
    check to SKUs that just ran out."""
    fresh_skus = {i.sku for i in fresh_items(s, household_id)}
    ever = {i.sku for i in s.exec(select(Item).where(Item.household_id == household_id))}
    open_rows = list(s.exec(select(ShoppingListItem).where(ShoppingListItem.household_id == household_id,
                                                           ShoppingListItem.done == False)))  # noqa: E712
    on_list = {r.sku for r in open_rows if r.sku} | {r.name.lower() for r in open_rows}
    added = []
    for info in staples():
        if only is not None and info.sku not in only:
            continue
        if info.sku in ever and info.sku not in fresh_skus and info.sku not in on_list \
                and info.display_name.lower() not in on_list:
            row = ShoppingListItem(household_id=household_id, name=info.display_name, sku=info.sku,
                                   source="auto", confirmed=False, added_at=now)
            s.add(row)
            added.append(row)
    s.flush()
    return added
