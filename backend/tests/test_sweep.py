from datetime import timedelta

from sqlmodel import Session, select

from app.demo.seed import create_basket_purchase
from app.models import PendingAction
from app.nessie.banking import execute_transfer, offer_sweep
from app.nessie.client import running_balance
from app.nessie.sync import sync_now

from .conftest import household, run, text


def setup_offer(ctx):
    text(ctx, "hi")
    hh = household(ctx)
    run(create_basket_purchase(ctx, hh.checking_account_id, "weekly"))  # $42.18
    run(sync_now(ctx))
    msg = run(offer_sweep(ctx, hh, "sweep:test"))
    return hh, msg


def transfers(ctx):
    return list(ctx.nessie.state["transfers"].values())


def test_offer_moves_no_money(seeded):
    ctx = seeded
    hh, msg = setup_offer(ctx)
    assert msg == "🏦 You're $32.82 under budget this week.\nMove $32.00 to Grocery Fund? Reply YES or NO."
    assert transfers(ctx) == []
    # Unrelated chatter never moves money either.
    for t in ("sure thing buddy", "move it", "transfer", "fridge"):
        text(ctx, t)
    assert transfers(ctx) == []


def test_yes_transfers_exactly_the_offer(seeded):
    ctx = seeded
    hh, _ = setup_offer(ctx)
    reply = text(ctx, "YES")
    assert len(transfers(ctx)) == 1 and transfers(ctx)[0]["amount"] == 32
    # Nessie keeps static balances; the app computes them from its records.
    assert run(running_balance(ctx.nessie, hh.grocery_fund_account_id)) == 152
    deposits = list(ctx.nessie.state["deposits"].values())
    assert len(deposits) == 1 and deposits[0]["account_id"] == hh.grocery_fund_account_id
    assert reply.startswith("✅ Moved $32.00 → Grocery Fund")
    # Checking: 1850 minus the $42 purchase (whole dollars) minus the $32 transfer.
    assert reply.endswith("Checking: $1,776.00 · Grocery Fund: $152.00")
    # A second YES can't repeat it.
    assert text(ctx, "yes").startswith("Nothing is waiting")
    assert len(transfers(ctx)) == 1


def test_no_declines(seeded):
    ctx = seeded
    setup_offer(ctx)
    assert text(ctx, "no") == "👍 No problem, nothing moved."
    assert transfers(ctx) == []
    assert text(ctx, "yes").startswith("Nothing is waiting")
    assert transfers(ctx) == []


def test_expired_offer_does_nothing(seeded):
    ctx = seeded
    setup_offer(ctx)
    ctx.clock.advance(hours=1)  # pending actions last 30 minutes
    assert text(ctx, "YES").startswith("⌛ That offer expired")
    assert transfers(ctx) == []


def test_claim_is_single_use(seeded):
    ctx = seeded
    hh, _ = setup_offer(ctx)
    with Session(ctx.engine) as s:
        a = s.exec(select(PendingAction).where(PendingAction.kind == "transfer")).one()
    run(execute_transfer(ctx, hh, a.id, 32))
    second = run(execute_transfer(ctx, hh, a.id, 32))
    assert second.startswith("⌛") and len(transfers(ctx)) == 1


def test_over_budget_makes_no_offer(seeded):
    ctx = seeded
    text(ctx, "hi")
    hh = household(ctx)
    for _ in range(2):
        run(create_basket_purchase(ctx, hh.checking_account_id, "weekly"))
    run(sync_now(ctx))
    msg = run(offer_sweep(ctx, hh, "sweep:over"))
    assert "Nothing left to move" in msg
    with Session(ctx.engine) as s:
        assert s.exec(select(PendingAction).where(PendingAction.kind == "transfer")).all() == []


def test_new_question_supersedes_offer(seeded):
    """YES answers the latest question, so an older money offer can't be confirmed by accident."""
    ctx = seeded
    setup_offer(ctx)
    text(ctx, "I finished the milk")  # asks to add milk to the list
    assert text(ctx, "yes").startswith("🛒 Added whole milk")
    assert transfers(ctx) == []
    assert timedelta  # keep import used
