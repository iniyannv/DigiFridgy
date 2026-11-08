"""Seed synthetic Nessie data: one demo household, its two accounts, four
fictional merchants, and two weeks of backdated purchases.

    python -m app.demo.seed            # idempotent: reuses IDs stored in SQLite
"""
from __future__ import annotations

import asyncio
import json
import logging
from datetime import timedelta
from pathlib import Path

from sqlmodel import Session

from ..context import Ctx, build_ctx
from ..fridge.parse import build_description
from ..households import get_obj, provision_household, put_obj

DATA = json.loads(Path(__file__).with_name("baskets.json").read_text())
DEMO_NAME = "Rivera Household"
log = logging.getLogger("seed")


def generation(ctx: Ctx) -> int:
    with Session(ctx.engine) as s:
        return int(get_obj(s, "demo:generation") or 0)


def bump_generation(ctx: Ctx) -> int:
    with Session(ctx.engine) as s:
        g = int(get_obj(s, "demo:generation") or 0) + 1
        put_obj(s, "demo:generation", str(g))
        s.commit()
        return g


async def ensure_merchants(ctx: Ctx) -> dict[str, str]:
    ids = {}
    for key, m in DATA["merchants"].items():
        with Session(ctx.engine) as s:
            mid = get_obj(s, f"merchant:{key}")
        if not mid:
            mid = await ctx.nessie.create_merchant(m["name"], m["category"], m["address"], m["geocode"])
            with Session(ctx.engine) as s:
                put_obj(s, f"merchant:{key}", mid)
                s.commit()
        ids[key] = mid
        ctx.merchant_cache[mid] = {"_id": mid, "name": m["name"], "category": [m["category"]]}
    return ids


def basket_payload(basket: dict) -> tuple[float, str]:
    if "lines" in basket:
        lines = [(sku, int(q), float(t)) for sku, q, t in basket["lines"]]
        return round(sum(t for _, _, t in lines), 2), build_description(lines)
    return float(basket["amount"]), basket.get("description", "Purchase")


async def create_basket_purchase(ctx: Ctx, account_id: str, basket_name: str, days_ago: int = 0) -> str:
    basket = DATA["baskets"][basket_name]
    merchants = await ensure_merchants(ctx)
    amount, desc = basket_payload(basket)
    pdate = (ctx.clock.today() - timedelta(days=days_ago)).isoformat()
    return await ctx.nessie.create_purchase(account_id, merchants[basket["merchant"]], amount, pdate, desc)


async def seed(ctx: Ctx, with_history: bool = True):
    from ..nessie.sync import sync_now

    gen = generation(ctx)
    hh = await provision_household(ctx, DEMO_NAME, "Alex", "Rivera", is_demo=True,
                                   key=f"household:demo{gen}", lookup_by_name=(gen == 0))
    if with_history:
        await seed_history(ctx, hh, sync=False)
    await sync_now(ctx)  # history is older than a day, so it stocks silently
    return hh


async def seed_history(ctx: Ctx, hh, sync: bool = True) -> None:
    """Two weeks of backdated purchases for one household (once per account)."""
    from ..nessie.sync import sync_now

    merchants = await ensure_merchants(ctx)
    with Session(ctx.engine) as s:
        done = get_obj(s, f"history:{hh.checking_account_id}")
    if not done and await ctx.nessie.list_purchases(hh.checking_account_id):
        done = "existing"  # a teammate already seeded this customer in Nessie
    if not done:
        for h in DATA["history"]:
            amount, desc = basket_payload(h)
            pdate = (ctx.clock.today() - timedelta(days=h["days_ago"])).isoformat()
            await ctx.nessie.create_purchase(hh.checking_account_id, merchants[h["merchant"]], amount, pdate, desc)
        with Session(ctx.engine) as s:
            put_obj(s, f"history:{hh.checking_account_id}", "1")
            s.commit()
    if sync:
        await sync_now(ctx)


async def _main() -> None:
    logging.basicConfig(level=logging.INFO)
    ctx = build_ctx()
    hh = await seed(ctx)
    mode = "SIMULATED (mock Nessie)" if ctx.nessie.is_mock else "live Nessie"
    print(f"Seeded {hh.name} [{mode}]")
    print(f"  customer   {hh.nessie_customer_id}")
    print(f"  checking   {hh.checking_account_id}")
    print(f"  grocery fund {hh.grocery_fund_account_id}")
    await ctx.nessie.close()


if __name__ == "__main__":
    asyncio.run(_main())
