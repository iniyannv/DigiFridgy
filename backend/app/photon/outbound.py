"""Sending: replies to an incoming message, and proactive texts to a household.

Every send has a stable idempotency key. Photon dedupes on it, and the local
`sent_messages` table stops repeats across restarts.
"""
from __future__ import annotations

import logging

from sqlmodel import Session, select

from ..context import Ctx
from ..models import Member, SentMessage

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


async def _send(ctx: Ctx, member: Member, text: str, key: str, parent_id: str | None = None) -> bool:
    if not member.photon_space_id or not member.agent_user_id or member.status != "active":
        return False
    with Session(ctx.engine) as s:
        if _already_sent(s, key):
            return False
    try:
        await ctx.photon.send_message(member.photon_space_id, member.agent_user_id, text, key, parent_id)
    except Exception:
        log.exception("send failed (key=%s)", key)
        return False
    with Session(ctx.engine) as s:
        if not _already_sent(s, key):
            s.add(SentMessage(idempotency_key=key, member_id=member.id, text=text, sent_at=ctx.clock.real_now()))
            s.commit()
    return True


async def send_reply(ctx: Ctx, member: Member, incoming_id: str, text: str) -> bool:
    return await _send(ctx, member, text, f"reply:{incoming_id}", parent_id=incoming_id)


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
