"""Time-based jobs. Each tick reads `clock.now()`, so a demo time-skip fires
them right away. `job_runs` keys make each job run once per item/week."""
from __future__ import annotations

import asyncio
import logging
from datetime import timedelta

from sqlalchemy.exc import IntegrityError
from sqlmodel import Session, select

from ..brain import copy, pending
from ..context import Ctx
from ..fridge import inventory
from ..models import Household, Item, JobRun
from ..photon.outbound import notify_household

log = logging.getLogger("scheduler")

NUDGE_WITHIN = timedelta(days=1)
INSIGHT_HOUR = 17  # Sunday, local time
SWEEP_HOUR = 18


def once(s: Session, key: str, now) -> bool:
    """True the first time a key is seen."""
    if s.get(JobRun, key):
        return False
    s.add(JobRun(key=key, ran_at=now))
    try:
        s.flush()
        return True
    except IntegrityError:
        s.rollback()
        return False


async def expire_and_report(ctx: Ctx, hh: Household) -> list[Item]:
    now = ctx.clock.now()
    with Session(ctx.engine) as s:
        expired = inventory.expire_due(s, hh.id, now)
        if not expired:
            return []
        w0, w1 = inventory.week_bounds(ctx.clock)
        m0, m1 = inventory.month_bounds(ctx.clock)
        week = sum(w.amount for w in inventory.waste_between(s, hh.id, w0, w1))
        month = sum(w.amount for w in inventory.waste_between(s, hh.id, m0, m1))
        text = copy.expired_notice(expired, week, month)
        key = "expired:" + ",".join(str(i.id) for i in expired)
        s.commit()
    await notify_household(ctx, hh.id, text, key)
    return expired


async def nudge_expiring(ctx: Ctx, hh: Household) -> list[Item]:
    """One day before expiry: ask, so expiry is a choice, not a silent charge."""
    now = ctx.clock.now()
    with Session(ctx.engine) as s:
        due = [i for i in inventory.fresh_items(s, hh.id) if now < i.expires_at <= now + NUDGE_WITHIN]
        new = [i for i in due if once(s, f"nudge:{i.id}", now)]
        if not new:
            s.commit()
            return []
        # Several units of one SKU make one nudge.
        by_sku = {}
        for i in new:
            by_sku.setdefault(i.sku, i)
        items = list(by_sku.values())
        if len(items) == 1:
            pending.create(s, hh.id, "nudge", {"item_id": items[0].id}, now, minutes=24 * 60)
            text = copy.nudge_one(items[0], ctx.clock)
        else:
            text = copy.nudge_many(items, ctx.clock)
        key = "nudge:" + ",".join(str(i.id) for i in items)
        s.commit()
    await notify_household(ctx, hh.id, text, key)
    return items


async def weekly_jobs(ctx: Ctx, hh: Household) -> None:
    from ..nessie.banking import insight, offer_sweep

    local = ctx.clock.local_now()
    if local.weekday() != 6:
        return
    week = ctx.clock.week_start().isoformat()
    now = ctx.clock.now()
    if local.hour >= INSIGHT_HOUR:
        with Session(ctx.engine) as s:
            first = once(s, f"insight:{hh.id}:{week}", now)
            text = copy.money(insight(ctx, s, hh)) if first else None
            s.commit()
        if text:
            await notify_household(ctx, hh.id, text, f"insight:{hh.id}:{week}")
    if local.hour >= SWEEP_HOUR:
        with Session(ctx.engine) as s:
            first = once(s, f"sweep:{hh.id}:{week}", now)
            s.commit()
        if first:
            await offer_sweep(ctx, hh, f"sweep:{hh.id}:{week}")


async def tick(ctx: Ctx) -> dict:
    # Pending actions expire lazily when answered, so a late YES gets "that offer expired".
    with Session(ctx.engine) as s:
        households = list(s.exec(select(Household)))
    summary = {"expired": 0, "nudged": 0}
    for hh in households:
        try:
            summary["expired"] += len(await expire_and_report(ctx, hh))
            summary["nudged"] += len(await nudge_expiring(ctx, hh))
            await weekly_jobs(ctx, hh)
        except Exception:
            log.exception("scheduler failed for household %s", hh.id)
    return summary


_lock = asyncio.Lock()


async def tick_now(ctx: Ctx) -> dict:
    async with _lock:
        return await tick(ctx)


async def scheduler_loop(ctx: Ctx) -> None:
    while True:
        try:
            await tick_now(ctx)
        except Exception:
            log.exception("scheduler loop error")
        await asyncio.sleep(ctx.settings.scheduler_interval)
