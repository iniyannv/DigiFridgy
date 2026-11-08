"""Reimagined grocery banking: purchase breakdown, budget streak, list estimate, roommate settle-up."""
import pytest
from sqlmodel import Session, select

from app import money
from app.brain.commands import answer_yes_no, update_item
from app.demo.seed import create_basket_purchase
from app.households import provision_household
from app.models import Household, PendingAction, ProcessedPurchase, Settlement
from app.nessie.sync import sync_now
from app.signup import remember_app_member
from app.spacetime import bridge
from app.spacetime.client import MockSpacetimeClient

from .conftest import household, outbox_texts, run, text


def buy(ctx, hh, basket="weekly", days_ago=0):
    pid = run(create_basket_purchase(ctx, hh.checking_account_id, basket, days_ago=days_ago))
    run(sync_now(ctx))
    return pid


def purchase(ctx, pid) -> ProcessedPurchase:
    with Session(ctx.engine) as s:
        return s.get(ProcessedPurchase, pid)


# ---------- what happened to each purchase ----------

def test_purchase_breakdown_adds_up(seeded):
    ctx = seeded
    text(ctx, "hi")
    hh = household(ctx)
    pid = buy(ctx, hh)
    text(ctx, "used milk")
    text(ctx, "tossed spinach")
    with Session(ctx.engine) as s:
        b = money.purchase_breakdown(s, hh.id, pid, purchase(ctx, pid).amount)
    assert b["eaten"] == 3.49 and b["wasted"] == 2.99
    assert b["in_fridge"] == pytest.approx(42.18 - 3.49 - 2.99)
    assert b["eaten"] + b["wasted"] + b["in_fridge"] + b["not_added"] + b["other"] == pytest.approx(42.18)
    assert "whole milk" in b["names"]["eaten"] and "spinach" in b["names"]["wasted"]


def test_trips_and_money_texts(seeded):
    ctx = seeded
    text(ctx, "hi")
    buy(ctx, household(ctx))
    text(ctx, "used milk")
    reply = text(ctx, "where did my money go")
    assert "$42.18 at" in reply and "$3.49 eaten" in reply and "still in the fridge" in reply
    assert "Last trip:" in text(ctx, "money")


# ---------- budget streak ----------

def test_streak_counts_completed_weeks_under_budget(seeded):
    ctx = seeded
    text(ctx, "hi")
    hh = household(ctx)
    buy(ctx, hh, days_ago=7)    # last week: $42.18
    buy(ctx, hh, days_ago=14)   # the week before
    with Session(ctx.engine) as s:
        st = money.budget_streak(ctx, s, s.get(Household, hh.id))
    assert st.weeks == 2 and st.week_left == 75.0
    text(ctx, "budget 40")      # now both weeks were over
    with Session(ctx.engine) as s:
        assert money.budget_streak(ctx, s, s.get(Household, hh.id)).weeks == 0


def test_sweeps_count_as_saved(seeded):
    from app.nessie.banking import offer_sweep
    ctx = seeded
    text(ctx, "hi")
    hh = household(ctx)
    buy(ctx, hh)
    run(offer_sweep(ctx, hh, "sweep:t"))
    text(ctx, "yes")
    with Session(ctx.engine) as s:
        assert money.budget_streak(ctx, s, s.get(Household, hh.id)).saved == 32.0
    assert "$32.00 saved to Grocery Fund" in text(ctx, "money")


# ---------- shopping list estimate ----------

def test_list_estimate_uses_what_you_paid(seeded):
    ctx = seeded
    text(ctx, "hi")
    buy(ctx, household(ctx))
    text(ctx, "add milk")
    text(ctx, "add coffee")
    reply = text(ctx, "list")
    assert "≈ $3.49 for the 1 you've bought before" in reply
    assert "left in this week's budget" in reply


# ---------- roommates ----------

@pytest.fixture
def flat(seeded):
    """Alex (demo household, texts from HANDLE) and Sam (own Nessie customer) share one app fridge."""
    ctx = seeded
    ctx.spacetime = MockSpacetimeClient()
    text(ctx, "hi")
    alex = household(ctx)
    run(bridge.sync_now(ctx))
    code = bridge.invite_code(ctx, alex.id)
    sam = run(provision_household(ctx, "Sam's Household (roommate)", "Sam", "Roommate", is_demo=False,
                                  key="roommate:test:sam", lookup_by_name=False))
    ok, _ = run(bridge.join_app_household(ctx, sam, code))
    assert ok
    return ctx, alex, sam, code


def app_household(ctx, hh) -> str:
    with Session(ctx.engine) as s:
        return money.app_household_of(s, hh.id)


def app_user_of(ctx, hh, code) -> str:
    """An iPhone app user who connected `hh`'s bank (identity remembered at sign-up)."""
    identity, token = run(ctx.spacetime.create_identity())
    run(ctx.spacetime.call(token, "join_household", [code]))
    remember_app_member(ctx, identity, hh.id)
    return token


def app_item(ctx, token, name_part):
    return next((k, v) for k, v in ctx.spacetime.app_items(token).items() if name_part in v["name"].lower())


def test_roommate_who_eats_owes_the_payer(flat):
    ctx, alex, sam, code = flat
    buy(ctx, alex)                        # Alex's card pays for the weekly groceries
    run(bridge.sync_now(ctx))
    update_item(ctx, sam.id, "milk", "used")     # Sam: USED milk (iMessage)
    run(bridge.sync_now(ctx))
    sam_phone = app_user_of(ctx, sam, code)
    eggs_id, _ = app_item(ctx, sam_phone, "egg")
    run(ctx.spacetime.call(sam_phone, "use_item", [eggs_id, 1, "Eggs"]))   # Sam taps −1 in the app
    run(bridge.sync_now(ctx))
    alex_phone = app_user_of(ctx, alex, code)
    yogurt_id, _ = app_item(ctx, alex_phone, "yogurt")
    run(ctx.spacetime.call(alex_phone, "use_item", [yogurt_id, 1, "Yogurt"]))  # Alex ate their own: free
    run(bridge.sync_now(ctx))

    state = run(money.settle_state(ctx, app_household(ctx, alex)))
    assert [(d.from_id, d.to_id, d.amount) for d in state.debts] == [(sam.id, alex.id, 3.49 + 2.79)]
    assert set(state.debts[0].items) == {"whole milk", "eggs"}
    # The backend's iMessage use also went into SpacetimeDB's shared log, next to the app taps.
    assert {u["name"].lower() for u in ctx.spacetime.households[app_household(ctx, alex)].uses} \
        == {"whole milk", "eggs", "yogurt"}


def test_settle_needs_yes_and_pays_once(flat):
    ctx, alex, sam, code = flat
    buy(ctx, alex)
    run(bridge.sync_now(ctx))
    update_item(ctx, sam.id, "milk", "used")
    update_item(ctx, sam.id, "chicken", "used")
    run(bridge.sync_now(ctx))
    reply = run(money.offer(ctx, sam))
    assert "You owe Rivera Household $12.47" in reply and "Send Rivera Household $12" in reply
    transfers_before = len(ctx.nessie.state["transfers"])
    assert len(ctx.nessie.state["transfers"]) == transfers_before   # an offer moves nothing
    done = run(answer_yes_no(ctx, sam, True))
    assert done.startswith("✅ Sent Rivera Household $12")
    assert len(ctx.nessie.state["transfers"]) == transfers_before + 1
    assert any("Sam sent you $12 for groceries" in t for t in outbox_texts(ctx))
    # 47 cents left: below a dollar, so no new offer and a second YES does nothing.
    state = run(money.settle_state(ctx, app_household(ctx, alex)))
    assert [(d.from_id, round(d.amount, 2)) for d in state.debts] == [(sam.id, 0.47)]
    assert run(answer_yes_no(ctx, sam, True)).startswith("Nothing is waiting on a yes/no")
    with Session(ctx.engine) as s:
        assert len(list(s.exec(select(Settlement)))) == 1


def test_double_tap_in_the_app_pays_once(flat):
    import asyncio
    ctx, alex, sam, _ = flat
    buy(ctx, alex)
    run(bridge.sync_now(ctx))
    update_item(ctx, sam.id, "chicken", "used")
    run(bridge.sync_now(ctx))
    app_hh = app_household(ctx, alex)

    async def both():
        return await asyncio.gather(money.pay(ctx, app_hh, sam.id, alex.id), money.pay(ctx, app_hh, sam.id, alex.id))
    results = run(both())
    assert [ok for ok, _ in results].count(True) == 1


def test_iMessage_uses_still_count_on_an_old_module(flat, monkeypatch):
    ctx, alex, sam, _ = flat
    buy(ctx, alex)
    run(bridge.sync_now(ctx))
    update_item(ctx, sam.id, "milk", "used")
    run(bridge.sync_now(ctx))
    real = ctx.spacetime.query

    async def old_module(token, sql):
        if "my_item_uses" in sql:
            raise RuntimeError("no such table `my_item_uses`")
        return await real(token, sql)
    monkeypatch.setattr(ctx.spacetime, "query", old_module)
    state = run(money.settle_state(ctx, app_household(ctx, alex)))
    assert not state.app_uses_available
    assert [(d.from_id, d.amount) for d in state.debts] == [(sam.id, 3.49)]


def test_settle_without_roommates_explains(seeded):
    ctx = seeded
    ctx.spacetime = MockSpacetimeClient()
    text(ctx, "hi")
    run(bridge.sync_now(ctx))
    assert "connects their own bank" in text(ctx, "settle up")
    with Session(ctx.engine) as s:
        assert not list(s.exec(select(PendingAction).where(PendingAction.kind == "settle")))
