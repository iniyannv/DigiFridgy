"""Photon, people in the loop: household group chat + claims, photos of receipts, tapbacks,
and questions answered in the app (SpacetimeDB approvals)."""
import json

import pytest
from sqlmodel import Session, select

from app.demo.seed import create_basket_purchase
from app.models import Item, ListClaim, PendingAction, ShoppingListItem
from app.nessie.sync import sync_now
from app.photon.inbound import handle_raw
from app.spacetime import bridge
from app.spacetime.client import MockSpacetimeClient

from .conftest import BASE, HANDLE, household, outbox_texts, run, text

SAM = "+15555550199"


def group_say(ctx, handle: str, body: str, group: str = "flat") -> str:
    before = len(ctx.photon.outbox)
    run(handle_raw(ctx, ctx.photon.inject(handle, body, created_at=BASE, group=group)))
    new = ctx.photon.outbox[before:]
    return new[-1]["text"] if new else ""


@pytest.fixture
def flatmates(seeded):
    ctx = seeded
    text(ctx, "hi")
    text(ctx, "hi", handle=SAM)  # joins the same (demo) household
    with Session(ctx.engine) as s:
        from app.models import Member
        for m in s.exec(select(Member)):
            m.display_name = "Alex" if m.photon_handle == HANDLE else "Sam"
            s.add(m)
        s.commit()
    return ctx


# ---------- group chat ----------

def test_first_member_links_the_group(flatmates):
    ctx = flatmates
    assert "fridge chat" in group_say(ctx, HANDLE, "hey fridge")
    assert "Shopping list" in group_say(ctx, SAM, "list") or "list is empty" in group_say(ctx, SAM, "list")
    # Replies go to the group, not anyone's 1:1 chat.
    assert all(m["spaceId"] == ctx.photon._spaces["group:flat"] for m in ctx.photon.group_conversation("flat"))


def test_strangers_in_the_group_are_ignored(flatmates):
    ctx = flatmates
    group_say(ctx, HANDLE, "hi")
    assert group_say(ctx, "+15555550111", "what's expiring?") == ""


def test_who_is_grabbing_milk(flatmates):
    ctx = flatmates
    group_say(ctx, HANDLE, "hi")
    ask = group_say(ctx, HANDLE, "who's grabbing milk?")
    assert "Alex asks: who's grabbing" in ask and "I WILL" in ask
    assert "Sam's grabbing" in group_say(ctx, SAM, "I will")
    assert "Sam already said" in group_say(ctx, HANDLE, "i'll get milk")
    assert "(Sam's got it)" in group_say(ctx, HANDLE, "list")


def test_claim_by_name_adds_it_to_the_list(flatmates):
    ctx = flatmates
    assert "Sam's grabbing" in text(ctx, "i'll grab eggs", handle=SAM)
    with Session(ctx.engine) as s:
        assert [r.name.lower() for r in s.exec(select(ShoppingListItem))] == ["eggs"]


def test_money_needs_the_account_holders_own_chat(flatmates):
    from app.nessie.banking import offer_sweep
    ctx = flatmates
    group_say(ctx, HANDLE, "hi")
    hh = household(ctx)
    run(create_basket_purchase(ctx, hh.checking_account_id, "weekly"))
    run(sync_now(ctx))
    run(offer_sweep(ctx, hh, "sweep:t"))
    assert "Money only moves" in group_say(ctx, SAM, "yes")
    assert not ctx.nessie.state["transfers"]
    assert "Moved" in text(ctx, "yes")


# ---------- photos ----------

class FakeVision:
    def __init__(self, kind="receipt", items=None):
        self.result = {"kind": kind, "items": items if items is not None else [
            {"name": "Whole Milk 1 gal", "qty": 1, "price": 3.49},
            {"name": "Large Eggs", "qty": 1, "price": 2.79},
            {"name": "Baby Spinach", "qty": 2, "price": 5.98},
            {"name": "Paper towels", "qty": 1, "price": 4.99}]}

    async def read_items(self, image, mime):
        return self.result

    async def classify(self, text):
        return None


def send_photo(ctx, handle=HANDLE):
    before = len(ctx.photon.outbox)
    run(handle_raw(ctx, ctx.photon.inject(handle, image=b"\xff\xd8fakejpeg", created_at=BASE)))
    return ctx.photon.outbox[before:][-1]["text"]


def fresh_names(ctx):
    with Session(ctx.engine) as s:
        return sorted(i.name for i in s.exec(select(Item).where(Item.status == "fresh")))


def test_receipt_photo_needs_a_yes(seeded):
    ctx = seeded
    ctx.llm = FakeVision()
    text(ctx, "hi")
    reply = send_photo(ctx)
    assert "From your receipt" in reply and "1) " in reply and "Paper towels" in reply  # not food: listed as skipped
    assert "Add these 3?" in reply
    assert fresh_names(ctx) == []
    assert "Dropped eggs" in text(ctx, "2")
    assert "Added 3 items" in text(ctx, "yes")  # milk + 2 spinach
    assert fresh_names(ctx) == ["spinach", "spinach", "whole milk"]


def test_fridge_photo_skips_what_is_already_tracked(seeded):
    ctx = seeded
    text(ctx, "hi")
    run(create_basket_purchase(ctx, household(ctx).checking_account_id, "weekly"))
    run(sync_now(ctx))
    ctx.llm = FakeVision("food", [{"name": "milk", "qty": 1, "price": None},
                                  {"name": "butter", "qty": 1, "price": None}])
    reply = send_photo(ctx)
    assert "I can see" in reply and "butter" in reply and "already tracked" in reply


def test_photo_without_a_reader_says_so(seeded):
    ctx = seeded
    text(ctx, "hi")
    assert "photo reading" in send_photo(ctx)


# ---------- tapbacks ----------

def last_agent_message_id(ctx):
    return ctx.photon.outbox[-1]["id"]


def test_thumbs_up_answers_a_question(seeded):
    ctx = seeded
    ctx.llm = FakeVision()
    text(ctx, "hi")
    send_photo(ctx)
    asked = last_agent_message_id(ctx)
    before = len(ctx.photon.outbox)
    run(handle_raw(ctx, ctx.photon.inject(HANDLE, created_at=BASE, reaction="like", parent_id=asked)))
    assert "Added" in ctx.photon.outbox[before:][-1]["text"]


def test_tapback_never_moves_money(seeded):
    from app.nessie.banking import offer_sweep
    ctx = seeded
    text(ctx, "hi")
    hh = household(ctx)
    run(create_basket_purchase(ctx, hh.checking_account_id, "weekly"))
    run(sync_now(ctx))
    run(offer_sweep(ctx, hh, "sweep:t"))
    asked = last_agent_message_id(ctx)
    before = len(ctx.photon.outbox)
    run(handle_raw(ctx, ctx.photon.inject(HANDLE, created_at=BASE, reaction="like", parent_id=asked)))
    assert "typed YES" in ctx.photon.outbox[before:][-1]["text"]
    assert not ctx.nessie.state["transfers"]


def test_tapback_on_an_old_message_is_ignored(seeded):
    ctx = seeded
    ctx.llm = FakeVision()
    old = None
    text(ctx, "hi")
    old = last_agent_message_id(ctx)
    send_photo(ctx)
    before = len(ctx.photon.outbox)
    run(handle_raw(ctx, ctx.photon.inject(HANDLE, created_at=BASE, reaction="like", parent_id=old)))
    assert ctx.photon.outbox[before:] == []


# ---------- approve in the app ----------

@pytest.fixture
def shared(seeded):
    ctx = seeded
    ctx.spacetime = MockSpacetimeClient()
    ctx.llm = FakeVision()
    text(ctx, "hi")
    run(bridge.sync_now(ctx))
    return ctx


def app_phone(ctx, owner=True):
    from app.signup import remember_app_member
    identity, token = run(ctx.spacetime.create_identity())
    run(ctx.spacetime.call(token, "join_household", [bridge.invite_code(ctx, household(ctx).id)]))
    if owner:
        remember_app_member(ctx, identity, household(ctx).id)
    return token


def approvals(ctx, token):
    return run(ctx.spacetime.query(token, "SELECT * FROM my_approvals"))


def test_question_shows_up_in_the_app_and_can_be_answered_there(shared):
    ctx = shared
    phone = app_phone(ctx, owner=False)
    send_photo(ctx)
    run(bridge.sync_now(ctx))
    [q] = approvals(ctx, phone)
    assert q["title"] == "Add 3 items from a photo" and not q["money"]  # 3 products: milk, eggs, spinach ×2
    run(ctx.spacetime.call(phone, "decide_approval", [q["id"], True]))
    run(bridge.sync_now(ctx))
    assert approvals(ctx, phone) == []
    assert fresh_names(ctx) == ["eggs", "spinach", "spinach", "whole milk"]
    assert any("said yes in the app" in t for t in outbox_texts(ctx))


def test_answering_by_text_clears_the_app_card(shared):
    ctx = shared
    phone = app_phone(ctx)
    send_photo(ctx)
    run(bridge.sync_now(ctx))
    assert len(approvals(ctx, phone)) == 1
    text(ctx, "no")
    run(bridge.sync_now(ctx))
    assert approvals(ctx, phone) == []


def test_money_in_the_app_only_from_the_account_holder(shared):
    from app.nessie.banking import offer_sweep
    ctx = shared
    hh = household(ctx)
    run(create_basket_purchase(ctx, hh.checking_account_id, "weekly"))
    run(sync_now(ctx))
    run(offer_sweep(ctx, hh, "sweep:t"))
    run(bridge.sync_now(ctx))
    stranger = app_phone(ctx, owner=False)
    [q] = approvals(ctx, stranger)
    assert q["money"]
    run(ctx.spacetime.call(stranger, "decide_approval", [q["id"], True]))
    run(bridge.sync_now(ctx))
    assert not ctx.nessie.state["transfers"]
    assert any("Only" in t and "can approve moving their money" in t for t in outbox_texts(ctx))
    [again] = approvals(ctx, stranger)  # back open for the right person
    assert again["status"] == "open"
    owner = app_phone(ctx)
    run(ctx.spacetime.call(owner, "decide_approval", [again["id"], True]))
    run(bridge.sync_now(ctx))
    assert len(ctx.nessie.state["transfers"]) == 1


def test_claims_sync_with_the_app(shared):
    ctx = shared
    phone = app_phone(ctx)
    text(ctx, "i'll get milk")
    run(bridge.sync_now(ctx))
    [entry] = ctx.spacetime.app_shopping(phone).values()
    assert entry["claimedBy"] and entry["name"].lower() == "whole milk"
    # Someone claims bread in the app.
    text(ctx, "add bread")
    run(bridge.sync_now(ctx))
    eid, bread = next((k, v) for k, v in ctx.spacetime.app_shopping(phone).items() if "bread" in v["name"].lower())
    run(ctx.spacetime.call(phone, "save_shopping_item", [eid, json.dumps({**bread, "claimedBy": "Jordan"})]))
    run(bridge.sync_now(ctx))
    assert "(Jordan's got it)" in text(ctx, "list")
    with Session(ctx.engine) as s:
        assert {c.name for c in s.exec(select(ListClaim))} >= {"Jordan"}
