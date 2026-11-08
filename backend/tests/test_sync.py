from sqlmodel import Session, select

from app.demo.seed import create_basket_purchase
from app.models import Item, ProcessedPurchase
from app.nessie.sync import sync_now

from .conftest import household, outbox_texts, run, text


def test_purchase_stocks_fridge_and_texts(seeded):
    ctx = seeded
    text(ctx, "hi")
    hh = household(ctx)
    run(create_basket_purchase(ctx, hh.checking_account_id, "weekly"))
    assert run(sync_now(ctx)) == 1
    with Session(ctx.engine) as s:
        assert len(s.exec(select(Item).where(Item.status == "fresh")).all()) == 9
    stocked = outbox_texts(ctx)[-1]
    assert stocked.startswith("🧊 Stocked 9 items from Avon Fresh Market ($42.18)")
    assert "Reply FRIDGE" in stocked


def test_sync_is_idempotent(seeded):
    ctx = seeded
    text(ctx, "hi")
    hh = household(ctx)
    run(create_basket_purchase(ctx, hh.checking_account_id, "weekly"))
    run(sync_now(ctx))
    sent = len(ctx.photon.outbox)
    assert run(sync_now(ctx)) == 0
    from app.nessie.sync import process_purchase
    purchase = run(ctx.nessie.list_purchases(hh.checking_account_id))[0]
    assert run(process_purchase(ctx, hh, purchase)) is False  # same ID again
    with Session(ctx.engine) as s:
        assert len(s.exec(select(Item)).all()) == 9
        assert len(s.exec(select(ProcessedPurchase)).all()) == 1
    assert len(ctx.photon.outbox) == sent


def test_non_grocery_purchase_is_ignored_for_items(seeded):
    ctx = seeded
    text(ctx, "hi")
    hh = household(ctx)
    run(create_basket_purchase(ctx, hh.checking_account_id, "fuel"))
    run(sync_now(ctx))
    with Session(ctx.engine) as s:
        assert s.exec(select(Item)).all() == []
        p = s.exec(select(ProcessedPurchase)).one()
        assert p.is_grocery is False and p.amount == 38  # Nessie keeps whole dollars
    assert not any("Stocked" in t for t in outbox_texts(ctx))


def test_history_is_stocked_silently(ctx):
    from app.demo.seed import seed
    text(ctx, "hi")  # joins (and seeds) the demo household with history
    run(seed(ctx, with_history=True))
    assert not any("Stocked" in t for t in outbox_texts(ctx))
    with Session(ctx.engine) as s:
        items = s.exec(select(Item)).all()
        assert items
        # Old perishables are assumed eaten, never counted as waste.
        assert all(i.status in ("fresh", "used") for i in items)
