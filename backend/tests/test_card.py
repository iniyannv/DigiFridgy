"""Card purchases wait for the person: YES by text, or pick items in the app."""
from fastapi.testclient import TestClient
from sqlmodel import Session, select

from app.demo.seed import create_basket_purchase
from app.main import create_app
from app.models import Item
from app.nessie.sync import sync_now

from .conftest import household, outbox_texts, run, text


def buy(ctx, basket="weekly"):
    ctx.settings.auto_stock = False
    text(ctx, "hi")
    pid = run(create_basket_purchase(ctx, household(ctx).checking_account_id, basket))
    run(sync_now(ctx))
    return pid


def fresh_count(ctx):
    with Session(ctx.engine) as s:
        return len(s.exec(select(Item).where(Item.status == "fresh")).all())


def test_purchase_asks_instead_of_stocking(seeded):
    ctx = seeded
    buy(ctx)
    assert fresh_count(ctx) == 0
    q = outbox_texts(ctx)[-1]
    assert q.startswith("🧾 Card purchase at Avon Fresh Market ($42.18): whole milk, spinach, chicken breast +6 more")
    assert "Reply YES or NO" in q


def test_yes_stocks_everything_once(seeded):
    ctx = seeded
    buy(ctx)
    assert text(ctx, "YES").startswith("🧊 Stocked 9 items from Avon Fresh Market ($42.18)")
    assert fresh_count(ctx) == 9
    assert text(ctx, "yes").startswith("Nothing is waiting")
    assert fresh_count(ctx) == 9


def test_no_leaves_it_for_later(seeded):
    ctx = seeded
    buy(ctx)
    assert text(ctx, "no").startswith("👍 Not added")
    assert fresh_count(ctx) == 0


def test_pick_lines_in_the_app(seeded):
    ctx = seeded
    pid = buy(ctx)
    c = TestClient(create_app(ctx))
    listing = c.get("/demo/purchases").json()["purchases"]
    p = next(x for x in listing if x["purchase_id"] == pid)
    assert len(p["lines"]) == 9 and all(li["status"] == "pending" for li in p["lines"])
    r = c.post(f"/demo/purchases/{pid}/stock", json={"lines": [0, 1]}).json()  # milk, spinach
    assert r["added"] == 2 and r["names"] == ["spinach", "whole milk"]
    assert fresh_count(ctx) == 2
    assert outbox_texts(ctx)[-1].startswith("🧊 Added 2 items from the app")
    # Adding the same lines again does nothing; YES adds only what's left.
    assert c.post(f"/demo/purchases/{pid}/stock", json={"lines": [0, 1]}).json()["added"] == 0
    assert text(ctx, "YES").startswith("🧊 Stocked 7 items")
    assert fresh_count(ctx) == 9
    lines = next(x for x in c.get("/demo/purchases").json()["purchases"] if x["purchase_id"] == pid)["lines"]
    assert all(li["status"] == "stocked" for li in lines)


def test_adding_everything_in_the_app_closes_the_text_question(seeded):
    ctx = seeded
    pid = buy(ctx)
    c = TestClient(create_app(ctx))
    assert c.post(f"/demo/purchases/{pid}/stock", json={}).json()["added"] == 9
    assert text(ctx, "yes").startswith("Nothing is waiting")


def test_history_is_stocked_and_listed_as_added(ctx):
    from app.demo.seed import seed
    ctx.settings.auto_stock = False
    run(seed(ctx, with_history=True))
    c = TestClient(create_app(ctx))
    listing = c.get("/demo/purchases").json()["purchases"]
    assert listing and all(li["status"] == "stocked" for p in listing for li in p["lines"])


def test_backfill_saves_lines_for_older_purchases(seeded):
    from app.card import backfill
    from app.models import CardPurchaseLine
    ctx = seeded
    ctx.settings.auto_stock = True
    text(ctx, "hi")
    run(create_basket_purchase(ctx, household(ctx).checking_account_id, "weekly"))
    run(sync_now(ctx))
    with Session(ctx.engine) as s:  # simulate a purchase synced before this feature
        for row in s.exec(select(CardPurchaseLine)):
            s.delete(row)
        s.commit()
    assert run(backfill(ctx)) == 1
    assert run(backfill(ctx)) == 0
    with Session(ctx.engine) as s:
        rows = s.exec(select(CardPurchaseLine)).all()
        assert len(rows) == 9 and all(r.status == "stocked" for r in rows)
