"""Banking features: grocery spend, waste totals, the weekly budget sweep."""
from __future__ import annotations

import logging
from dataclasses import dataclass, field
from datetime import date, timedelta

from sqlmodel import Session, select

from ..brain import copy, pending
from ..context import Ctx
from ..fridge import inventory
from ..models import Household, ProcessedPurchase
from ..photon.outbound import notify_household

log = logging.getLogger("banking")


def grocery_spend(s: Session, household_id: int, start: date, end: date) -> float:
    rows = s.exec(select(ProcessedPurchase).where(ProcessedPurchase.household_id == household_id,
                                                  ProcessedPurchase.is_grocery == True,  # noqa: E712
                                                  ProcessedPurchase.purchase_date >= start,
                                                  ProcessedPurchase.purchase_date < end))
    return round(sum(r.amount for r in rows), 2)


@dataclass
class Insight:
    week_spend: float
    last_week_spend: float
    budget: float
    week_waste: float
    week_waste_names: list[str] = field(default_factory=list)
    month_waste: float = 0.0
    month_spend: float = 0.0


def insight(ctx: Ctx, s: Session, hh: Household) -> Insight:
    clock = ctx.clock
    ws = clock.week_start()
    today = clock.today()
    month_start = today.replace(day=1)
    w_start, w_end = inventory.week_bounds(clock)
    m_start, m_end = inventory.month_bounds(clock)
    week_waste = inventory.waste_between(s, hh.id, w_start, w_end)
    names = []
    for w in week_waste:
        if w.item_name not in names:
            names.append(w.item_name)
    return Insight(
        week_spend=grocery_spend(s, hh.id, ws, ws + timedelta(days=7)),
        last_week_spend=grocery_spend(s, hh.id, ws - timedelta(days=7), ws),
        budget=hh.weekly_budget,
        week_waste=round(sum(w.amount for w in week_waste), 2),
        week_waste_names=names,
        month_waste=round(sum(w.amount for w in inventory.waste_between(s, hh.id, m_start, m_end)), 2),
        month_spend=grocery_spend(s, hh.id, month_start, today + timedelta(days=1)),
    )


async def offer_sweep(ctx: Ctx, hh: Household, key: str) -> str | None:
    """If under budget this week, asks to move the difference. Never moves money itself."""
    if not hh.grocery_fund_account_id:
        return None
    with Session(ctx.engine) as s:
        ins = insight(ctx, s, hh)
        under = round(ins.budget - ins.week_spend, 2)
        if under < 1:
            text = copy.over_budget(ins)
        else:
            pending.create(s, hh.id, "transfer", {"amount": under, "week": str(ctx.clock.week_start())},
                           ctx.clock.now())
            text = copy.sweep_offer(under)
        s.commit()
    await notify_household(ctx, hh.id, text, key)
    return text


async def _balance(ctx: Ctx, account_id: str) -> float | None:
    try:
        return float((await ctx.nessie.get_account(account_id)).get("balance"))
    except Exception:
        log.warning("balance lookup failed for %s", account_id)
        return None


async def execute_transfer(ctx: Ctx, hh: Household, action_id: int, amount: float) -> str:
    """Runs only after an explicit YES. The atomic claim guarantees one transfer per offer."""
    now = ctx.clock.now()
    if not pending.claim_open(ctx.engine, action_id, now):
        return copy.offer_expired()
    before_c = await _balance(ctx, hh.checking_account_id)
    before_f = await _balance(ctx, hh.grocery_fund_account_id)
    try:
        await ctx.nessie.create_transfer(hh.checking_account_id, hh.grocery_fund_account_id, amount,
                                         "DigiFridgey weekly grocery budget sweep",
                                         ctx.clock.today().isoformat())
    except Exception:
        log.exception("transfer failed")
        pending.finish(ctx.engine, action_id, "failed")
        return copy.transfer_failed()
    pending.finish(ctx.engine, action_id, "done")
    after_c = await _balance(ctx, hh.checking_account_id)
    after_f = await _balance(ctx, hh.grocery_fund_account_id)
    posted = after_c is not None and before_c is not None and abs(after_c - before_c) > 0.004
    if not posted and before_c is not None and before_f is not None:
        # Nessie hasn't applied it to balances yet; show the expected result.
        return copy.transfer_done(amount, before_c - amount, before_f + amount, pending_post=True)
    return copy.transfer_done(amount, after_c, after_f, pending_post=False)
