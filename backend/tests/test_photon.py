import copy as _copy

from sqlmodel import Session, select

from app.demo.seed import create_basket_purchase
from app.models import Member
from app.nessie.sync import sync_now
from app.photon.client import parse_message
from app.photon.inbound import handle_raw, poll_once

from .conftest import BASE, HANDLE, household, outbox_texts, run, text


def test_first_message_registers_and_welcomes(seeded):
    ctx = seeded
    reply = text(ctx, "hello")
    assert reply.startswith("👋 Hi! I'm DigiFridgy")
    with Session(ctx.engine) as s:
        m = s.exec(select(Member)).one()
        assert m.photon_handle == HANDLE and m.photon_space_id and m.agent_user_id


def test_dedupe_by_message_id(seeded):
    ctx = seeded
    raw = ctx.photon.inject(HANDLE, "hi", created_at=BASE)
    assert run(handle_raw(ctx, raw)) is True
    assert run(handle_raw(ctx, raw)) is False
    assert len(ctx.photon.outbox) == 1


def test_polling_dedupes_overlapping_windows(seeded):
    ctx = seeded
    ctx.photon.inject(HANDLE, "hi", created_at=BASE)
    run(poll_once(ctx))
    run(poll_once(ctx))
    assert len(ctx.photon.outbox) == 1


def test_ignores_own_messages_and_strangers_in_groups(seeded):
    ctx = seeded
    raw = ctx.photon.inject(HANDLE, "hi", created_at=BASE)
    own = _copy.deepcopy(raw)
    own["id"] += "x"
    own["sentBy"] = dict(own["receivedBy"])
    own["sentBy"]["kind"] = "human"  # even if mislabeled, same ID as the agent
    assert run(handle_raw(ctx, own)) is False
    agent_kind = _copy.deepcopy(raw)
    agent_kind["id"] += "y"
    agent_kind["sentBy"]["kind"] = "agent"
    assert run(handle_raw(ctx, agent_kind)) is False
    group = _copy.deepcopy(raw)
    group["id"] += "z"
    group["space"]["kind"] = "group"
    run(handle_raw(ctx, group))  # groups pass the guards, but this number isn't a member yet
    assert ctx.photon.outbox == []


def test_allowlist(seeded):
    ctx = seeded
    ctx.settings.allowed_handles = ["+19995550000"]
    text(ctx, "hi")
    assert ctx.photon.outbox == []


def test_reply_idempotency_key_is_stable(seeded):
    ctx = seeded
    raw = ctx.photon.inject(HANDLE, "hi", created_at=BASE)
    run(handle_raw(ctx, raw))
    sent = ctx.photon.outbox[0]
    assert sent["idempotencyKey"] == f"reply:{raw['id']}"
    assert sent["parentMessageId"] == raw["id"]
    assert sent["senderId"] == raw["receivedBy"]["id"]
    assert sent["spaceId"] == raw["space"]["id"]


def test_proactive_keys_are_stable_and_not_resent(seeded):
    ctx = seeded
    text(ctx, "hi")
    pid = run(create_basket_purchase(ctx, household(ctx).checking_account_id, "weekly"))
    run(sync_now(ctx))
    key = ctx.photon.outbox[-1]["idempotencyKey"]
    assert f"stock:{pid}:m" in key
    from app.photon.outbound import notify_household
    assert run(notify_household(ctx, household(ctx).id, "again", f"stock:{pid}")) == 0


def test_stop_halts_messages(seeded):
    ctx = seeded
    text(ctx, "hi")
    assert text(ctx, "STOP").startswith("You're unsubscribed")
    run(create_basket_purchase(ctx, household(ctx).checking_account_id, "weekly"))
    run(sync_now(ctx))
    assert not any("Stocked" in t for t in outbox_texts(ctx))
    assert text(ctx, "fridge") == ""  # silent until START
    assert text(ctx, "START").startswith("👋 Welcome back")


def test_parse_message_handles_non_text():
    m = parse_message({"id": "pho_msg_1", "createdAt": "2026-11-08T00:00:00.000Z", "status": "received",
                       "platform": "imessage", "sentBy": {"id": "u1", "kind": "human", "handle": "+1"},
                       "receivedBy": {"id": "a1", "kind": "agent", "handle": "+2"},
                       "space": {"id": "s1", "kind": "direct"}, "content": {"type": "image"}})
    assert m is not None and m.text is None
    assert parse_message({"nope": True}) is None


def test_ambiguous_match_asks(seeded):
    ctx = seeded
    text(ctx, "hi")
    hh = household(ctx)
    run(create_basket_purchase(ctx, hh.checking_account_id, "weekly"))
    run(create_basket_purchase(ctx, hh.checking_account_id, "oat"))
    run(sync_now(ctx))
    q = text(ctx, "finished the milk")
    assert q.startswith("Which milk?") and "1) whole milk" in q and "2) oat milk" in q
    assert text(ctx, "2").startswith("✅ Marked the oat milk as used.")


def test_category_needs_confirmation(seeded):
    ctx = seeded
    text(ctx, "hi")
    run(create_basket_purchase(ctx, household(ctx).checking_account_id, "weekly"))
    run(sync_now(ctx))
    q = text(ctx, "finished the produce")
    assert q.startswith("Mark all 3 produce items as used?")
    assert text(ctx, "yes") == "✅ Marked 3 produce items as used."
