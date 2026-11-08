"""Tapbacks as answers: 👍 or ❤️ on the question I just asked means YES, 👎 means NO. Only for
questions that don't move money; transfers and settle-ups still need a typed YES."""
from __future__ import annotations

from datetime import timedelta

from sqlmodel import Session, select

from ..context import Ctx
from ..models import AgentMessage, Household
from ..photon.client import Inbound
from . import pending

YES = {"like", "love", "heart", "liked", "loved", "thumbsup", "thumbs_up", "thumbs-up", "+1",
       "\U0001F44D", "❤️", "❤", "♥️"}
NO = {"dislike", "disliked", "thumbsdown", "thumbs_down", "thumbs-down", "-1", "\U0001F44E"}
MONEY_KINDS = ("transfer", "settle")


def meaning(reaction: str | None) -> bool | None:
    r = (reaction or "").strip().lower()
    if r in YES or r.startswith("\U0001F44D"):
        return True
    if r in NO or r.startswith("\U0001F44E"):
        return False
    return None


async def handle(ctx: Ctx, hh: Household, m: Inbound) -> str | None:
    """Returns the reply, or None when the tapback isn't an answer (then we stay quiet)."""
    from .commands import answer_yes_no
    if m.reaction_action not in (None, "add") or not m.parent_message_id:
        return None
    yes = meaning(m.reaction)
    if yes is None:
        return None
    with Session(ctx.engine) as s:
        asked = s.get(AgentMessage, m.parent_message_id)
        if asked is None or asked.household_id != hh.id:
            return None
        a = pending.latest(s, hh.id, pending.YES_NO_KINDS)
        if a is None or pending.is_expired(a, ctx.clock.now()):
            return None
        # Only the message that asked the current question counts. Proactive texts (purchase posted,
        # budget sweep) aren't tied to a question id: then it has to be my latest message in that chat.
        if asked.action_id is not None:
            if asked.action_id != a.id:
                return None
        else:
            from sqlalchemy import literal_column
            latest = s.exec(select(AgentMessage).where(AgentMessage.space_id == asked.space_id)
                            .order_by(literal_column("rowid").desc())).first()
            if latest is None or latest.photon_message_id != asked.photon_message_id \
                    or asked.sent_at < a.created_at - timedelta(seconds=5):
                return None
        if a.kind in MONEY_KINDS:
            return "💳 For money, reply with a typed YES. A tapback isn't enough."
        action_id = a.id
    return await answer_yes_no(ctx, hh, yes, action_id=action_id)
