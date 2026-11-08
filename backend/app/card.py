"""Card purchases as an input, like a scanned receipt: the products on a recent
grocery purchase wait for the person to add them, by texting YES or by picking
lines in the app (Add from card). Old purchases (seed history) are stocked silently.
"""
from __future__ import annotations

from datetime import datetime, time, timedelta

from sqlmodel import Session, select

from .brain import copy, pending
from .context import Ctx
from .fridge import inventory
from .fridge.parse import LineItem
from .fridge.shelf_life import lookup
from .models import CardPurchaseLine, Household, Item, ProcessedPurchase

LIST_DAYS = 14


def record_lines(s: Session, household_id: int, purchase_id: str, lines: list[LineItem], status: str, now) -> None:
    for i, li in enumerate(lines):
        s.add(CardPurchaseLine(nessie_purchase_id=purchase_id, household_id=household_id, line_index=i,
                               sku=li.sku, qty=li.qty, total=li.total, status=status,
                               status_at=now if status != "pending" else None))


def _purchased_at(ctx: Ctx, record: ProcessedPurchase) -> datetime:
    today = ctx.clock.today()
    if record.purchase_date >= today:
        return record.processed_at
    return ctx.clock.local_to_utc(datetime.combine(record.purchase_date, time(12)))


def stock_lines(ctx: Ctx, s: Session, hh: Household, purchase_id: str,
                indexes: list[int] | None = None) -> list[Item]:
    """Stocks the chosen pending lines (all pending lines when `indexes` is None).
    Lines already stocked are skipped, so a double tap or a YES after the app pick is harmless."""
    now = ctx.clock.now()
    record = s.get(ProcessedPurchase, purchase_id)
    if record is None or record.household_id != hh.id:
        return []
    q = select(CardPurchaseLine).where(CardPurchaseLine.nessie_purchase_id == purchase_id,
                                       CardPurchaseLine.status == "pending")
    rows = [r for r in s.exec(q) if indexes is None or r.line_index in indexes]
    if not rows:
        return []
    lines = [LineItem(sku=r.sku, qty=r.qty, total=r.total) for r in rows]
    items = inventory.stock_items(s, hh.id, lines, _purchased_at(ctx, record), purchase_id, now)
    for r in rows:
        r.status, r.status_at = "stocked", now
        s.add(r)
    s.flush()
    if not pending_lines(s, purchase_id):
        close_question(s, hh.id, purchase_id)
    return [i for i in items if i.status == "fresh"]


def skip_rest(s: Session, hh: Household, purchase_id: str, now) -> int:
    rows = pending_lines(s, purchase_id)
    for r in rows:
        r.status, r.status_at = "skipped", now
        s.add(r)
    close_question(s, hh.id, purchase_id)
    return len(rows)


def pending_lines(s: Session, purchase_id: str) -> list[CardPurchaseLine]:
    return list(s.exec(select(CardPurchaseLine).where(CardPurchaseLine.nessie_purchase_id == purchase_id,
                                                      CardPurchaseLine.status == "pending")))


def close_question(s: Session, household_id: int, purchase_id: str) -> None:
    a = pending.latest(s, household_id, ("stock",))
    if a and pending.payload(a).get("purchase_id") == purchase_id:
        pending.set_status(s, a, "done")


def ask(s: Session, ctx: Ctx, household_id: int, purchase_id: str, merchant: str, amount: float,
        lines: list[LineItem]) -> str:
    # Lasts a day: people answer grocery texts later than money offers.
    pending.create(s, household_id, "stock", {"purchase_id": purchase_id}, ctx.clock.now(), minutes=24 * 60)
    names = [lookup(li.sku).display_name for li in lines]
    return copy.stock_question(merchant, amount, sum(li.qty for li in lines), names)


def list_purchases(ctx: Ctx, s: Session, household_id: int, days: int = LIST_DAYS) -> list[dict]:
    since = ctx.clock.today() - timedelta(days=days)
    records = s.exec(select(ProcessedPurchase).where(ProcessedPurchase.household_id == household_id,
                                                     ProcessedPurchase.is_grocery == True,  # noqa: E712
                                                     ProcessedPurchase.purchase_date >= since)
                     .order_by(ProcessedPurchase.purchase_date.desc(), ProcessedPurchase.processed_at.desc()))
    out = []
    for r in records:
        rows = list(s.exec(select(CardPurchaseLine).where(CardPurchaseLine.nessie_purchase_id == r.nessie_purchase_id)
                           .order_by(CardPurchaseLine.line_index)))
        if not rows:
            continue
        out.append({
            "purchase_id": r.nessie_purchase_id, "merchant": r.merchant_name, "date": r.purchase_date.isoformat(),
            "amount": r.amount,
            "lines": [{"index": x.line_index, "sku": x.sku, "name": lookup(x.sku).display_name,
                       "emoji": lookup(x.sku).emoji, "qty": x.qty, "total": x.total,
                       "shelf_life_days": lookup(x.sku).shelf_life_days, "status": x.status} for x in rows],
        })
    return out


async def backfill(ctx: Ctx) -> int:
    """Purchases synced before card review existed have no saved lines. Re-read them from
    Nessie once; their items were stocked automatically back then, so lines are 'stocked'."""
    from .fridge.parse import parse_description
    with Session(ctx.engine) as s:
        have = set(s.exec(select(CardPurchaseLine.nessie_purchase_id)).all())
        missing = [r for r in s.exec(select(ProcessedPurchase).where(ProcessedPurchase.is_grocery == True))  # noqa: E712
                   if r.nessie_purchase_id not in have and r.item_count]
        households = {h.id: h for h in s.exec(select(Household))}
    filled = 0
    by_hh: dict[int, list[ProcessedPurchase]] = {}
    for r in missing:
        by_hh.setdefault(r.household_id, []).append(r)
    for hh_id, records in by_hh.items():
        hh = households.get(hh_id)
        if not hh or not hh.checking_account_id:
            continue
        nessie = {p.get("_id"): p for p in await ctx.nessie.list_purchases(hh.checking_account_id)}
        with Session(ctx.engine) as s:
            for r in records:
                p = nessie.get(r.nessie_purchase_id)
                parsed = parse_description(p.get("description")) if p else None
                if parsed and parsed.items:
                    record_lines(s, hh_id, r.nessie_purchase_id, parsed.items, "stocked", ctx.clock.now())
                    filled += 1
            s.commit()
    return filled
