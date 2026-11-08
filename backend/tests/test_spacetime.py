"""Shared fridge: backend inventory <-> the iOS app's SpacetimeDB household (mock SpacetimeDB)."""
import json
import uuid

import pytest
from sqlmodel import Session, select

from app.demo.seed import create_basket_purchase
from app.models import Item
from app.nessie.sync import sync_now
from app.spacetime import bridge
from app.spacetime.client import MockSpacetimeClient

from .conftest import household, outbox_texts, run, text


@pytest.fixture
def shared(seeded):
    ctx = seeded
    ctx.spacetime = MockSpacetimeClient()
    text(ctx, "hi")
    return ctx


def app_user(ctx) -> str:
    """An iPhone app user who joined the backend household's app household with the invite code."""
    _, token = run(ctx.spacetime.create_identity())
    run(ctx.spacetime.call(token, "join_household", [bridge.invite_code(ctx, household(ctx).id)]))
    return token


def fresh(ctx, name_part: str) -> list[Item]:
    with Session(ctx.engine) as s:
        return [i for i in s.exec(select(Item).where(Item.status == "fresh")) if name_part in i.name]


def buy_weekly(ctx):
    run(create_basket_purchase(ctx, household(ctx).checking_account_id, "weekly"))
    run(sync_now(ctx))


def app_item_json(name: str, category: str, expires_ms: int, estimated: bool = True) -> str:
    return json.dumps({"id": "x", "name": name, "category": category, "count": 1, "addedAt": expires_ms - 864e5,
                       "addedBy": "app", "expiresAt": expires_ms, "expiryIsEstimated": estimated,
                       "source": "barcode", "allergens": []})


def test_purchase_shows_up_in_the_app(shared):
    ctx = shared
    buy_weekly(ctx)
    run(bridge.sync_now(ctx))
    items = ctx.spacetime.app_items(app_user(ctx))
    assert sum(i["count"] for i in items.values()) == 9
    by_name = {i["name"].lower(): i for i in items.values()}
    milk = next(v for k, v in by_name.items() if "milk" in k)
    assert milk["category"] == "milk" and milk["expiryIsEstimated"] is True and "milk" in milk["allergens"]
    assert next(v for k, v in by_name.items() if "egg" in k)["category"] == "eggs"


def test_first_sync_texts_the_invite_code(shared):
    ctx = shared
    run(bridge.sync_now(ctx))
    code = bridge.invite_code(ctx, household(ctx).id)
    assert code and any(code in t and "app" in t for t in outbox_texts(ctx))
    assert code in text(ctx, "APP")


def test_used_over_imessage_removes_it_from_the_app(shared):
    ctx = shared
    buy_weekly(ctx)
    run(bridge.sync_now(ctx))
    token = app_user(ctx)
    assert any("milk" in i["name"].lower() for i in ctx.spacetime.app_items(token).values())
    text(ctx, "I finished the milk")
    run(bridge.sync_now(ctx))
    assert not any("milk" in i["name"].lower() for i in ctx.spacetime.app_items(token).values())


def test_item_added_in_app_reaches_imessage(shared):
    ctx = shared
    run(bridge.sync_now(ctx))
    token = app_user(ctx)
    expires = int((ctx.clock.real_now().timestamp() + 5 * 86400) * 1000)
    run(ctx.spacetime.call(token, "upsert_item", ["app-avocado", 3, app_item_json("Hass Avocados", "avocado", expires)]))
    run(bridge.sync_now(ctx))
    assert len(fresh(ctx, "avocado")) == 3
    assert "avocado" in text(ctx, "FRIDGE").lower()


def test_app_count_change_and_imessage_change_merge(shared):
    ctx = shared
    run(bridge.sync_now(ctx))
    token = app_user(ctx)
    expires = int((ctx.clock.real_now().timestamp() + 5 * 86400) * 1000)
    run(ctx.spacetime.call(token, "upsert_item", ["app-yogurt", 4, app_item_json("Greek Yogurt", "yogurt", expires)]))
    run(bridge.sync_now(ctx))
    assert len(fresh(ctx, "yogurt")) == 4
    # Meanwhile: app user adds 2, someone texts that they used one.
    run(ctx.spacetime.call(token, "increment_count", ["app-yogurt", 2]))
    text(ctx, "I ate the greek yogurt")
    run(bridge.sync_now(ctx))
    assert len(fresh(ctx, "yogurt")) == 5
    assert ctx.spacetime.app_items(token)["app-yogurt"]["count"] == 5
    run(bridge.sync_now(ctx))  # stable
    assert ctx.spacetime.app_items(token)["app-yogurt"]["count"] == 5 and len(fresh(ctx, "yogurt")) == 5


def test_deleted_in_app_is_marked_used(shared):
    ctx = shared
    buy_weekly(ctx)
    run(bridge.sync_now(ctx))
    token = app_user(ctx)
    eggs_id = next(k for k, v in ctx.spacetime.app_items(token).items() if "egg" in v["name"].lower())
    run(ctx.spacetime.call(token, "delete_item", [eggs_id]))
    run(bridge.sync_now(ctx))
    assert fresh(ctx, "egg") == []
    assert eggs_id not in ctx.spacetime.app_items(token)


def test_app_set_expiry_updates_backend(shared):
    ctx = shared
    run(bridge.sync_now(ctx))
    token = app_user(ctx)
    expires = int((ctx.clock.real_now().timestamp() + 2 * 86400) * 1000)
    run(ctx.spacetime.call(token, "upsert_item", ["app-milk", 1, app_item_json("Milk", "milk", expires, estimated=False)]))
    run(bridge.sync_now(ctx))
    later = expires + 6 * 86_400_000
    run(ctx.spacetime.call(token, "upsert_item", ["app-milk", 1, app_item_json("Milk", "milk", later, estimated=False)]))
    run(bridge.sync_now(ctx))
    (unit,) = fresh(ctx, "milk")
    assert abs(unit.expires_at.timestamp() - bridge._from_ms(ctx, later).timestamp()) < 2


def test_outage_does_not_double_count(shared):
    ctx = shared
    buy_weekly(ctx)
    run(bridge.sync_now(ctx))
    token = app_user(ctx)
    apples_id = next(k for k, v in ctx.spacetime.app_items(token).items() if "apple" in v["name"].lower())
    ctx.spacetime.fail_calls = True
    text(ctx, "finished the apples")
    run(bridge.sync_now(ctx))       # fails quietly
    ctx.spacetime.fail_calls = False
    run(ctx.spacetime.call(token, "increment_count", [apples_id, 2]))  # app: 1 -> 3
    run(bridge.sync_now(ctx))
    # 1 bought, -1 over iMessage, +2 in the app = 2 on both sides.
    assert len(fresh(ctx, "apple")) == 2
    assert ctx.spacetime.app_items(token)[apples_id]["count"] == 2


def test_failed_app_write_is_retried_without_double_count(shared):
    ctx = shared
    buy_weekly(ctx)
    run(bridge.sync_now(ctx))
    token = app_user(ctx)
    apples_id = next(k for k, v in ctx.spacetime.app_items(token).items() if "apple" in v["name"].lower())
    text(ctx, "finished the apples")
    ctx.spacetime.fail_reducers = True
    run(bridge.sync_now(ctx))       # backend applied, app write fails
    ctx.spacetime.fail_reducers = False
    run(ctx.spacetime.call(token, "increment_count", [apples_id, 2]))  # app: 1 -> 3
    run(bridge.sync_now(ctx))
    assert len(fresh(ctx, "apple")) == 2
    assert ctx.spacetime.app_items(token)[apples_id]["count"] == 2


def test_link_command_joins_an_existing_app_household(shared):
    ctx = shared
    buy_weekly(ctx)
    run(bridge.sync_now(ctx))
    # Someone already uses the app with their own household.
    _, token = run(ctx.spacetime.create_identity())
    run(ctx.spacetime.call(token, "create_household", [str(uuid.uuid4()), "Apartment 4B"]))
    code = run(ctx.spacetime.query(token, "SELECT * FROM my_household"))[0]["invite_code"]
    reply = text(ctx, f"LINK {code}")
    assert "Linked" in reply
    items = ctx.spacetime.app_items(token)
    assert sum(i["count"] for i in items.values()) == 9
    assert bridge.invite_code(ctx, household(ctx).id) == code


def test_link_with_bad_code(shared):
    ctx = shared
    run(bridge.sync_now(ctx))
    assert "Couldn't find" in text(ctx, "LINK ZZZZZZ")
    run(bridge.sync_now(ctx))  # recovers with a household of its own
    assert bridge.invite_code(ctx, household(ctx).id) not in (None, "ZZZZZZ")


def test_app_category_mapping():
    assert bridge.app_category("whole milk") == "milk"
    assert bridge.app_category("oat milk") == "plant_milk"
    assert bridge.app_category("baby spinach") == "leafy_greens"
    assert bridge.app_category("blueberry greek yogurt") == "yogurt"
    assert bridge.app_category("mystery thing") == "other"


def test_bank_items_carry_store_and_price(shared):
    ctx = shared
    buy_weekly(ctx)
    run(bridge.sync_now(ctx))
    items = ctx.spacetime.app_items(app_user(ctx))
    milk = next(i for i in items.values() if "milk" in i["name"].lower())
    assert milk["addedBy"] == "bank-purchase" and milk["source"] == "receipt"
    assert milk["store"] and milk["price"] > 0


def test_signup_from_the_app_joins_its_household(ctx):
    from fastapi.testclient import TestClient
    from app.main import create_app

    ctx.spacetime = MockSpacetimeClient()
    _, token = run(ctx.spacetime.create_identity())
    run(ctx.spacetime.call(token, "create_household", [str(uuid.uuid4()), "Apartment 4B"]))
    app_hh = run(ctx.spacetime.query(token, "SELECT * FROM my_household"))[0]
    c = TestClient(create_app(ctx))
    # Nobody linked a bank to this app household yet.
    assert c.get("/demo/state", params={"app_household_id": app_hh["id"]}).json()["household"] is None

    r = c.post("/signup", json={"first_name": "Maya", "phone": "(469) 555-0123",
                                "app_invite_code": app_hh["invite_code"].lower()}).json()
    assert r["app_linked"] is True
    st = c.get("/demo/state", params={"app_household_id": app_hh["id"]}).json()
    assert st["household"]["id"] == r["household_id"]
    assert st["household"]["app_household_id"] == app_hh["id"]
    assert st["handle"] == "+14695550123" and st["line"] == ctx.photon.agent_handle

    # A card purchase lands in the app household straight away.
    c.post("/demo/buy", params={"basket": "quick", "household_id": r["household_id"]})
    assert ctx.spacetime.app_items(token)
    assert bridge.invite_code(ctx, r["household_id"]) == app_hh["invite_code"]


def test_signup_with_a_bad_app_code_still_signs_up(ctx):
    ctx.spacetime = MockSpacetimeClient()
    from app.signup import sign_up
    r = run(sign_up(ctx, "Maya", None, "4695550123", app_invite_code="ZZZZZZ"))
    assert r.app_linked is False and "Couldn't find" in r.app_link_message
    assert r.household.id
