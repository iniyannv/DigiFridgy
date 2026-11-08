"""Inbound iMessages: polling loop (P0) and the shared handler used by the webhook.

Guards (from Photon's quickstart): only received messages, from a human, to
our agent, in a direct (1:1) conversation, never our own; optional handle
allowlist. Each message ID is processed once.
"""
from __future__ import annotations

import asyncio
import logging
from datetime import timedelta

from sqlalchemy.exc import IntegrityError
from sqlmodel import Session, select

from ..context import Ctx
from ..models import PhotonCursor, ProcessedMessage
from .client import Inbound, parse_message

log = logging.getLogger("inbound")

# Re-read a few seconds back to cover eventual consistency; dedupe makes it safe.
LOOKBACK = timedelta(seconds=10)


def assigned_lines(ctx: Ctx) -> set[str]:
    """Lines Photon assigned at sign-up. Each person may get a different pooled number."""
    from ..models import Member
    with Session(ctx.engine) as s:
        return {x for x in s.exec(select(Member.assigned_line)).all() if x}


def passes_guards(ctx: Ctx, m: Inbound) -> bool:
    st = ctx.settings
    if m.status != "received" or m.platform != st.photon_platform:
        return False
    if m.sender_kind != "human" or not m.agent_id or m.agent_kind != "agent":
        return False
    if m.sender_id == m.agent_id:
        return False  # our own message
    if st.photon_agent_handle and m.agent_handle != st.photon_agent_handle \
            and m.agent_handle not in assigned_lines(ctx):
        return False
    if st.photon_platform == "imessage" and m.space_kind != "direct":
        return False
    if st.allowed_handles and m.sender_handle not in st.allowed_handles:
        return False
    return True


def claim(ctx: Ctx, message_id: str) -> bool:
    """Atomically marks a message as processed. False if it already was."""
    with Session(ctx.engine) as s:
        s.add(ProcessedMessage(photon_message_id=message_id, processed_at=ctx.clock.real_now()))
        try:
            s.commit()
            return True
        except IntegrityError:
            return False


async def handle_raw(ctx: Ctx, raw: dict) -> bool:
    """Entry point for both polling and webhooks. Returns True if handled."""
    from ..brain.commands import handle_message

    m = parse_message(raw)
    if m is None or not passes_guards(ctx, m):
        return False
    if not claim(ctx, m.id):
        return False
    try:
        await handle_message(ctx, m)
    except Exception:
        log.exception("handler failed for message %s", m.id)
    from ..spacetime.bridge import request_sync
    request_sync(ctx)  # USED / ADD / … show up in the app right away
    return True


def _cursor(ctx: Ctx):
    with Session(ctx.engine) as s:
        row = s.get(PhotonCursor, 1)
        if row is None:
            # First run: start from now so old conversations aren't replayed.
            row = PhotonCursor(id=1, created_since=ctx.clock.real_now() - LOOKBACK)
            s.add(row)
            s.commit()
            s.refresh(row)
        return row.created_since


def _save_cursor(ctx: Ctx, value) -> None:
    with Session(ctx.engine) as s:
        row = s.get(PhotonCursor, 1) or PhotonCursor(id=1, created_since=value)
        if value > row.created_since:
            row.created_since = value
        s.add(row)
        s.commit()


async def poll_once(ctx: Ctx) -> int:
    since = _cursor(ctx) - LOOKBACK
    handled, newest, token = 0, None, None
    while True:
        items, token = await ctx.photon.list_messages(since, ctx.settings.photon_platform, token)
        for raw in items:
            m = parse_message(raw)
            if m and (newest is None or m.created_at > newest):
                newest = m.created_at
            if await handle_raw(ctx, raw):
                handled += 1
        if not token:
            break
    if newest:
        _save_cursor(ctx, newest)
    return handled


async def poll_loop(ctx: Ctx) -> None:
    while True:
        try:
            await poll_once(ctx)
        except Exception:
            log.exception("photon poll failed")
            await asyncio.sleep(5)
        await asyncio.sleep(ctx.settings.photon_poll_interval)
