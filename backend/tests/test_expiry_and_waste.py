from sqlmodel import Session, select

from app.demo.seed import create_basket_purchase
from app.models import Item, WasteEntry
from app.nessie.sync import sync_now
from app.scheduler.jobs import tick_now

from .conftest import household, outbox_texts, run, text


def stock(ctx, basket="weekly"):
    text(ctx, "hi")
    run(create_basket_purchase(ctx, household(ctx).checking_account_id, basket))
    run(sync_now(ctx))


def test_time_skip_expires_items_into_waste_ledger(seeded):
    ctx = seeded
    stock(ctx)
    assert run(tick_now(ctx))["expired"] == 0
    ctx.clock.advance(days=3)  # chicken (2 days) is now past expiry
    summary = run(tick_now(ctx))
    assert summary["expired"] == 1
    with Session(ctx.engine) as s:
        chicken = s.exec(select(Item).where(Item.sku == "chicken_breast_2lb")).one()
        assert chicken.status == "expired"
        waste = s.exec(select(WasteEntry)).one()
        assert waste.amount == 8.98 and waste.reason == "expired"
    assert any(t.startswith("🗑️ Expired: chicken breast ($8.98)") for t in outbox_texts(ctx))
    # Running again doesn't double-count.
    run(tick_now(ctx))
    with Session(ctx.engine) as s:
        assert len(s.exec(select(WasteEntry)).all()) == 1


def test_nudge_once_the_day_before(seeded):
    ctx = seeded
    stock(ctx)
    ctx.clock.advance(days=3, hours=1)  # strawberries (4 days) expire within a day
    run(tick_now(ctx))
    nudges = [t for t in outbox_texts(ctx) if t.startswith("⏰")]
    assert len(nudges) == 1 and "strawberries" in nudges[0]
    run(tick_now(ctx))
    assert len([t for t in outbox_texts(ctx) if t.startswith("⏰")]) == 1


def test_single_nudge_answered_by_bare_used(seeded):
    ctx = seeded
    stock(ctx, "quick")  # milk 7d, eggs 28d, bread 6d
    ctx.clock.advance(days=5, hours=1)  # only bread is within a day
    run(tick_now(ctx))
    assert "wheat bread expires tomorrow" in outbox_texts(ctx)[-1]
    reply = text(ctx, "USED")
    assert reply.startswith("✅ Marked the wheat bread as used.")


def test_tossed_records_waste(seeded):
    ctx = seeded
    stock(ctx)
    reply = text(ctx, "tossed the spinach")
    assert reply.startswith("🗑️ Tossed the spinach ($2.99 of food).")
    assert "Wasted this week: $2.99" in reply
    assert "Wasted: $2.99 (spinach)" in text(ctx, "MONEY")
