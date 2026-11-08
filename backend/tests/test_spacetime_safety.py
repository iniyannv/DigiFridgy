"""Shared fridge safety: relinking, malformed app rows, count bounds, lost responses, usage log (mock SpacetimeDB)."""
import json
import uuid
from datetime import timedelta

import pytest
from sqlmodel import Session, select

from app.demo.seed import create_basket_purchase
from app.models import Item, SpacetimeLink, UsageLog
from app.nessie.sync import sync_now
from app.spacetime import bridge
from app.spacetime.client import MockSpacetimeClient, SpacetimeError, is_unknown_reducer, not_applied

from .conftest import household, run, text


@pytest.fixture
def shared(seeded):
    ctx = seeded
    ctx.spacetime = MockSpacetimeClient()
    text(ctx, "hi")  # the welcome creates the app household (opt-in)
    return ctx


def app_user(ctx) -> str:
    _, token = run(ctx.spacetime.create_identity())
    run(ctx.spacetime.call(token, "join_household", [bridge.invite_code(ctx, household(ctx).id)]))
    return token


def units(ctx, name_part: str, status: str = "fresh") -> list[Item]:
    with Session(ctx.engine) as s:
        return [i for i in s.exec(select(Item).where(Item.status == status)) if name_part in i.name]


def buy_weekly(ctx):
    run(create_basket_purchase(ctx, household(ctx).checking_account_id, "weekly"))
    run(sync_now(ctx))


def item_json(name: str, ms: int = 1_800_000_000_000) -> str:
    return json.dumps({"id": "x", "name": name, "category": "other", "count": 1, "addedAt": ms - 86_400_000,
                       "addedBy": "app", "expiresAt": ms, "expiryIsEstimated": True, "source": "barcode",
                       "allergens": []})


def future_ms(ctx, days: int = 5) -> int:
    return int((ctx.clock.real_now().timestamp() + days * 86400) * 1000)


def link_of(ctx) -> SpacetimeLink:
    with Session(ctx.engine) as s:
        return s.get(SpacetimeLink, household(ctx).id)


# ---------- B7: linking never loses items ----------

def test_link_typo_keeps_items_and_link(shared):
    ctx = shared
    buy_weekly(ctx)
    run(bridge.sync_now(ctx))
    token = app_user(ctx)
    before_link = link_of(ctx)
    before_fresh = len(units(ctx, ""))
    before_app = ctx.spacetime.app_items(token)

    ok, msg = run(bridge.join_app_household(ctx, household(ctx), "ZZZZZZZZ"))
    assert not ok and "Couldn't find" in msg
    run(bridge.sync_now(ctx))

    after = link_of(ctx)
    assert (after.app_household_id, after.invite_code) == (before_link.app_household_id, before_link.invite_code)
    assert len(units(ctx, "")) == before_fresh and units(ctx, "", "used") == []
    assert ctx.spacetime.app_items(token) == before_app


def test_sync_skips_when_no_longer_a_member(shared):
    ctx = shared
    buy_weekly(ctx)
    run(bridge.sync_now(ctx))
    token = app_user(ctx)
    before = len(units(ctx, ""))
    run(ctx.spacetime.call(token, "kick_member", [link_of(ctx).identity]))  # or the database was wiped
    assert run(bridge.sync_now(ctx)).get("not_member") == 1
    assert len(units(ctx, "")) == before and units(ctx, "", "used") == []


def test_unlinked_household_is_not_synced(seeded):
    ctx = seeded
    ctx.spacetime = MockSpacetimeClient()
    assert run(bridge.sync_now(ctx)) == {}
    assert ctx.spacetime.households == {} and link_of(ctx) is None


def test_relink_moves_out_of_the_old_household(shared):
    ctx = shared
    run(bridge.sync_now(ctx))
    old_id = link_of(ctx).app_household_id
    _, token = run(ctx.spacetime.create_identity())
    run(ctx.spacetime.call(token, "create_household", [str(uuid.uuid4()), "Apartment 4B"]))
    code = run(ctx.spacetime.query(token, "SELECT * FROM my_household"))[0]["invite_code"]
    ok, _ = run(bridge.join_app_household(ctx, household(ctx), code))
    assert ok and link_of(ctx).invite_code == code
    assert old_id not in ctx.spacetime.households  # the bridge was its only member: cleaned up


# ---------- H5: malformed rows ----------

def test_malformed_row_is_skipped(shared):
    ctx = shared
    run(bridge.sync_now(ctx))
    token = app_user(ctx)
    run(ctx.spacetime.call(token, "upsert_item", ["app-good", 2, item_json("Hass Avocados", future_ms(ctx))]))
    run(bridge.sync_now(ctx))
    assert len(units(ctx, "avocado")) == 2
    hh = ctx.spacetime._hh(token)
    hh.items["app-good"]["data"] = "{not json"           # an existing item goes bad
    hh.items["app-list"] = {"count": 1, "data": "[1, 2]"}
    hh.items["app-count"] = {"count": "three", "data": item_json("Kale")}
    hh.items["app-new"] = {"count": 1, "data": item_json("Greek Yogurt", future_ms(ctx))}

    stats = run(bridge.sync_now(ctx))
    assert stats["skipped"] == 3
    assert len(units(ctx, "avocado")) == 2               # not read as "deleted in the app"
    assert len(units(ctx, "yogurt")) == 1                # the good row still syncs
    assert units(ctx, "kale") == []


def test_bad_timestamps_do_not_break_sync(shared):
    ctx = shared
    run(bridge.sync_now(ctx))
    token = app_user(ctx)
    data = json.loads(item_json("Milk"))
    data.update(expiresAt=1e30, addedAt=-5, expiryIsEstimated=False)
    run(ctx.spacetime.call(token, "upsert_item", ["app-milk", 1, json.dumps(data)]))
    run(bridge.sync_now(ctx))
    assert len(units(ctx, "milk")) == 1


# ---------- H4: count bounds ----------

def test_huge_count_is_capped(shared):
    ctx = shared
    run(bridge.sync_now(ctx))
    token = app_user(ctx)
    run(ctx.spacetime.call(token, "upsert_item", ["app-eggs", 2_000_000_000, item_json("Eggs", future_ms(ctx))]))
    assert ctx.spacetime.app_items(token)["app-eggs"]["count"] == 999   # the module clamps
    run(bridge.sync_now(ctx))
    assert len(units(ctx, "egg")) == bridge.MAX_UNITS_PER_ITEM
    assert ctx.spacetime.app_items(token)["app-eggs"]["count"] == bridge.MAX_UNITS_PER_ITEM
    run(bridge.sync_now(ctx))  # stable
    assert len(units(ctx, "egg")) == bridge.MAX_UNITS_PER_ITEM


def test_unclamped_count_from_an_old_module_is_capped(shared):
    ctx = shared
    run(bridge.sync_now(ctx))
    token = app_user(ctx)
    ctx.spacetime._hh(token).items["app-eggs"] = {"count": 2_000_000_000, "data": item_json("Eggs", future_ms(ctx))}
    run(bridge.sync_now(ctx))
    assert len(units(ctx, "egg")) == bridge.MAX_UNITS_PER_ITEM
    assert ctx.spacetime.app_items(token)["app-eggs"]["count"] == bridge.MAX_UNITS_PER_ITEM


def test_unit_creation_per_round_is_bounded(shared, monkeypatch):
    ctx = shared
    monkeypatch.setattr(bridge, "MAX_NEW_UNITS_PER_ROUND", 5)
    run(bridge.sync_now(ctx))
    token = app_user(ctx)
    for i in range(3):
        run(ctx.spacetime.call(token, "upsert_item", [f"app-{i}", 4, item_json(f"Thing {i}", future_ms(ctx))]))
    run(bridge.sync_now(ctx))
    assert len(units(ctx, "thing")) == 4                  # one item fits, the rest wait
    run(bridge.sync_now(ctx))
    run(bridge.sync_now(ctx))
    assert len(units(ctx, "thing")) == 12
    assert all(v["count"] == 4 for k, v in ctx.spacetime.app_items(token).items() if k.startswith("app-"))


# ---------- H3 / M5: absolute writes ----------

def _yogurt(ctx, count: int = 4) -> str:
    run(bridge.sync_now(ctx))
    token = app_user(ctx)
    run(ctx.spacetime.call(token, "upsert_item", ["app-yogurt", count, item_json("Greek Yogurt", future_ms(ctx))]))
    run(bridge.sync_now(ctx))
    assert len(units(ctx, "yogurt")) == count
    return token


def test_timeout_after_commit_does_not_double_decrement(shared):
    ctx = shared
    token = _yogurt(ctx)
    text(ctx, "I ate the greek yogurt")                    # backend 4 -> 3
    ctx.spacetime.timeout_after_commit = {"set_count_if"}
    run(bridge.sync_now(ctx))                               # app 4 -> 3 lands, the response is lost
    ctx.spacetime.timeout_after_commit = set()
    assert ctx.spacetime.app_items(token)["app-yogurt"]["count"] == 3
    run(bridge.sync_now(ctx))
    run(bridge.sync_now(ctx))
    assert ctx.spacetime.app_items(token)["app-yogurt"]["count"] == 3
    assert len(units(ctx, "yogurt")) == 3


def test_timeout_after_commit_on_export_does_not_double(shared):
    ctx = shared
    run(bridge.sync_now(ctx))
    token = app_user(ctx)
    ctx.spacetime.timeout_after_commit = {"upsert_item"}
    buy_weekly(ctx)
    run(bridge.sync_now(ctx))
    ctx.spacetime.timeout_after_commit = set()
    run(bridge.sync_now(ctx))
    assert sum(i["count"] for i in ctx.spacetime.app_items(token).values()) == 9
    assert len(units(ctx, "")) >= 9 and units(ctx, "", "used") == []


def test_concurrent_app_edit_is_not_overwritten(shared):
    ctx = shared
    token = _yogurt(ctx)
    text(ctx, "I ate the greek yogurt")                    # backend 4 -> 3

    real_call = ctx.spacetime.call

    async def tap_first(tok, reducer, args):               # the app taps +1 just before the bridge writes
        if reducer == "set_count_if" and not getattr(tap_first, "done", False):
            tap_first.done = True
            await real_call(token, "increment_count", ["app-yogurt", 1])
        return await real_call(tok, reducer, args)

    ctx.spacetime.call = tap_first
    run(bridge.sync_now(ctx))
    run(bridge.sync_now(ctx))
    # 4 - 1 (iMessage) + 1 (app) = 4 on both sides; nothing lost.
    assert ctx.spacetime.app_items(token)["app-yogurt"]["count"] == 4
    assert len(units(ctx, "yogurt")) == 4


def test_old_module_without_set_count_if_falls_back(shared):
    ctx = shared
    ctx.spacetime.missing_reducers = {"set_count_if"}
    token = _yogurt(ctx)
    text(ctx, "I ate the greek yogurt")
    run(bridge.sync_now(ctx))
    assert ctx.spacetime.app_items(token)["app-yogurt"]["count"] == 3
    assert [c for c in ctx.spacetime.calls if c[0] == "increment_count"] == [("increment_count", ["app-yogurt", -1])]


# ---------- M7: decrement vs delete ----------

def _expire_one(ctx, name_part: str) -> None:
    with Session(ctx.engine) as s:
        u = next(i for i in s.exec(select(Item).where(Item.status == "fresh")) if name_part in i.name)
        u.status = "expired"
        u.expires_at = ctx.clock.now() - timedelta(days=1)
        s.add(u)
        s.commit()


def test_app_decrement_uses_fresh_units_first(shared):
    ctx = shared
    token = _yogurt(ctx, 3)
    _expire_one(ctx, "yogurt")
    run(ctx.spacetime.call(token, "increment_count", ["app-yogurt", -1]))
    run(bridge.sync_now(ctx))
    assert len(units(ctx, "yogurt", "used")) == 1 and units(ctx, "yogurt", "tossed") == []
    assert len(units(ctx, "yogurt", "expired")) == 1


def test_app_delete_tosses_expired_units(shared):
    ctx = shared
    token = _yogurt(ctx, 3)
    _expire_one(ctx, "yogurt")
    run(ctx.spacetime.call(token, "delete_item", ["app-yogurt"]))
    run(bridge.sync_now(ctx))
    assert len(units(ctx, "yogurt", "tossed")) == 1 and len(units(ctx, "yogurt", "used")) == 2


# ---------- H2 / M6: usage log ----------

def test_used_over_imessage_is_logged_with_the_item_name(shared):
    ctx = shared
    token = _yogurt(ctx)
    text(ctx, "I ate the greek yogurt")
    run(bridge.sync_now(ctx))
    uses = ctx.spacetime._hh(token).uses
    assert [(u["item_id"], u["name"], u["qty"]) for u in uses] == [("app-yogurt", "Greek Yogurt", 1)]


def test_log_use_is_sent_in_chunks(shared):
    ctx = shared
    token = _yogurt(ctx)
    yogurt = units(ctx, "yogurt")[0]
    with Session(ctx.engine) as s:
        for _ in range(1500):
            s.add(UsageLog(household_id=household(ctx).id, item_id=yogurt.id, used_at=ctx.clock.now()))
        s.commit()
    assert run(bridge.push_uses(ctx, household(ctx), link_of(ctx))) == 1500
    assert sorted(u["qty"] for u in ctx.spacetime._hh(token).uses) == [500, 1000]


def test_missing_log_use_is_per_household_and_retried(shared, monkeypatch):
    ctx = shared
    token = _yogurt(ctx)
    ctx.spacetime.missing_reducers = {"log_use"}
    text(ctx, "I ate the greek yogurt")
    run(bridge.sync_now(ctx))
    assert ctx.spacetime._hh(token).uses == []
    ctx.spacetime.missing_reducers = set()                  # the module gets published
    run(bridge.sync_now(ctx))
    assert ctx.spacetime._hh(token).uses == []              # still waiting out the TTL
    monkeypatch.setattr(bridge.time, "monotonic", lambda: 1e12)
    run(bridge.sync_now(ctx))
    assert len(ctx.spacetime._hh(token).uses) == 1          # nothing was dropped meanwhile


def test_other_errors_do_not_disable_log_use(shared):
    ctx = shared
    _yogurt(ctx)
    assert not is_unknown_reducer(SpacetimeError("404: database not found"))
    assert is_unknown_reducer(SpacetimeError("404: no such reducer"))
    assert not_applied(SpacetimeError("530: Item not found.")) and not not_applied(SpacetimeError("503: busy"))


# ---------- H6: membership hygiene (mock mirrors the module) ----------

def test_leaving_rotates_the_code_and_empty_households_go_away(shared):
    ctx = shared
    run(bridge.sync_now(ctx))
    token = app_user(ctx)
    code = bridge.invite_code(ctx, household(ctx).id)
    assert len(code) == 8
    run(ctx.spacetime.call(token, "leave_household", []))
    run(bridge.sync_now(ctx))
    assert bridge.invite_code(ctx, household(ctx).id) != code   # the bridge picks up the new code
    with pytest.raises(SpacetimeError):
        run(ctx.spacetime.call(token, "join_household", [code]))


def test_join_attempts_are_limited(shared):
    ctx = shared
    _, token = run(ctx.spacetime.create_identity())
    for _ in range(10):
        with pytest.raises(SpacetimeError):
            run(ctx.spacetime.call(token, "join_household", ["WRONG123"]))
    with pytest.raises(SpacetimeError, match="Too many"):
        run(ctx.spacetime.call(token, "join_household", [bridge.invite_code(ctx, household(ctx).id)]))


# ---------- L5: subscription fan-out ----------

def test_subscription_update_syncs_only_that_household(shared):
    ctx = shared
    st = bridge._state(ctx)
    st.full, st.dirty = False, set()
    bridge.request_sync(ctx, 42)
    assert st.dirty == {42} and not st.full
    bridge.request_sync(ctx)
    assert st.full
