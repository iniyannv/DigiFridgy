"""Sending: replies to an incoming message, and proactive texts to a household.

Every send has a stable idempotency key. Photon dedupes on it, and the local
`sent_messages` table stops repeats across restarts.
"""
from __future__ import annotations

import logging

from sqlmodel import Session, select

from ..context import Ctx
from ..models import AgentMessage, HouseholdSpace, Member, SentMessage

log = logging.getLogger("outbound")


def _already_sent(s: Session, key: str) -> bool:
    return s.get(SentMessage, key) is not None


def key_salt(ctx: Ctx) -> str:
    """Per-database prefix for proactive keys. Local row IDs restart after a demo
    reset; the salt changes too, so Photon never sees a reused key."""
    if getattr(ctx, "_salt", None):
        return ctx._salt
    import secrets

    from ..models import NessieObject
    with Session(ctx.engine) as s:
        row = s.get(NessieObject, "db:salt")
        if row is None:
            row = NessieObject(key="db:salt", nessie_id=secrets.token_hex(4))
            s.add(row)
            s.commit()
            s.refresh(row)
        ctx._salt = row.nessie_id
    return ctx._salt


def reset_salt(ctx: Ctx) -> None:
    from ..models import NessieObject
    with Session(ctx.engine) as s:
        row = s.get(NessieObject, "db:salt")
        if row:
            s.delete(row)
            s.commit()
    ctx._salt = None


async def post(ctx: Ctx, space_id: str | None, sender_id: str | None, text: str, key: str,
               parent_id: str | None = None, household_id: int | None = None,
               member_id: int | None = None, action_id: int | None = None) -> bool:
    """Sends once per `key` and remembers the Photon message id (so a tapback on it can be matched)."""
    if not space_id or not sender_id:
        return False
    with Session(ctx.engine) as s:
        if _already_sent(s, key):
            return False
    try:
        sent = await ctx.photon.send_message(space_id, sender_id, text, key, parent_id) or {}
    except Exception:
        log.exception("send failed (key=%s)", key)
        return False
    with Session(ctx.engine) as s:
        if not _already_sent(s, key):
            s.add(SentMessage(idempotency_key=key, member_id=member_id, text=text, sent_at=ctx.clock.real_now()))
        msg_id = sent.get("id") or (sent.get("message") or {}).get("id")
        if household_id is not None and isinstance(msg_id, str) and msg_id != "replayed" \
                and s.get(AgentMessage, msg_id) is None:
            s.add(AgentMessage(photon_message_id=msg_id, household_id=household_id, space_id=space_id,
                               sent_at=ctx.clock.now(), action_id=action_id))
        s.commit()
    return True


async def _send(ctx: Ctx, member: Member, text: str, key: str, parent_id: str | None = None,
                action_id: int | None = None) -> bool:
    if not member.photon_space_id or not member.agent_user_id or member.status != "active":
        return False
    return await post(ctx, member.photon_space_id, member.agent_user_id, text, key, parent_id,
                      member.household_id, member.id, action_id)


async def send_reply(ctx: Ctx, member: Member, incoming_id: str, text: str, action_id: int | None = None) -> bool:
    return await _send(ctx, member, text, f"reply:{incoming_id}", parent_id=incoming_id, action_id=action_id)


async def reply_in(ctx: Ctx, space_id: str, agent_id: str, incoming_id: str, text: str, household_id: int,
                   action_id: int | None = None) -> bool:
    """Reply in the conversation the message came from (a 1:1 chat or the household group)."""
    return await post(ctx, space_id, agent_id, text, f"reply:{incoming_id}", incoming_id, household_id,
                      action_id=action_id)


async def notify_group(ctx: Ctx, household_id: int, text: str, key: str) -> bool:
    """Posts in the household's group chat, if it has one."""
    with Session(ctx.engine) as s:
        g = s.exec(select(HouseholdSpace).where(HouseholdSpace.household_id == household_id)
                   .order_by(HouseholdSpace.linked_at.desc())).first()
    if g is None:
        return False
    return await post(ctx, g.space_id, g.agent_user_id, text, f"{key_salt(ctx)}:{key}:g"[:255], None, household_id)


async def notify_household(ctx: Ctx, household_id: int, text: str, key: str) -> int:
    """Sends to every active member. `key` identifies the event (e.g. stock:<purchase id>)."""
    with Session(ctx.engine) as s:
        members = list(s.exec(select(Member).where(Member.household_id == household_id,
                                                   Member.status == "active")))
    sent = 0
    salt = key_salt(ctx)
    for m in members:
        if await _send(ctx, m, text, f"{salt}:{key}:m{m.id}"[:255]):
            sent += 1
    return sent
