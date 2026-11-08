"""Server tools for the ElevenLabs voice agent (calls arrive via Photon SIP).

Every request needs header `X-Tool-Secret: $VOICE_TOOL_SECRET`. Responses are
short sentences meant to be spoken (no emoji). The caller's number comes in header
`X-Caller-Id` (ElevenLabs: the `system__caller_id` variable) or ?handle=, in any format.
In DEMO_MODE an unknown caller gets the demo household.
"""
from __future__ import annotations

import hmac
import re

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel
from sqlmodel import Session, func, select

from ..brain import copy
from ..brain.commands import add_to_list, check_units
from ..fridge import inventory
from ..households import demo_household, member_by_handle
from ..models import Household
from ..photon.outbound import notify_household


def require_secret(request: Request) -> None:
    secret = request.app.state.ctx.settings.voice_tool_secret
    if not secret:
        raise HTTPException(503, "voice tools are not configured")
    given = request.headers.get("x-tool-secret", "")
    if not hmac.compare_digest(given.encode(), secret.encode()):
        raise HTTPException(401, "bad tool secret")


router = APIRouter(prefix="/voice/tools", dependencies=[Depends(require_secret)])


def _household(request: Request, handle: str | None) -> Household:
    from ..signup import normalize_handle
    ctx = request.app.state.ctx
    # ElevenLabs sends the caller as a header (an empty system__caller_id in a query param breaks its tools).
    handle = handle or request.headers.get("x-caller-id") or None
    with Session(ctx.engine) as s:
        if handle:
            # Caller ID arrives as "+19453288573", "19453288573" or "(945) 328-8573": same person.
            m = member_by_handle(s, normalize_handle(handle) or handle) or member_by_handle(s, handle)
            if m:
                return s.get(Household, m.household_id)
        if ctx.settings.demo_mode:
            # Browser tests of the agent have no caller ID: use the demo household, else the newest sign-up.
            hh = demo_household(s)
            if hh:
                return hh
            from ..models import Member
            m = s.exec(select(Member).where(Member.status == "active").order_by(Member.created_at.desc())).first()
            if m:
                return s.get(Household, m.household_id)
    raise HTTPException(404, "no household for this caller")


_NOT_SPOKEN = re.compile("[\U0001F000-\U0001FAFF\u2600-\u27BF\uFE0F\u200D]")


def _speak(text: str) -> str:
    """Chat text -> something a voice can read: no emoji, no "Reply 1-3" instructions."""
    text = _NOT_SPOKEN.sub("", text)
    return re.sub(r"\s+", " ", text).strip()


def _say_day(label: str) -> str:
    return {"today": "today", "tomorrow": "tomorrow", "expired": "already"}.get(label, f"by {label}")


@router.get("/fridge")
async def fridge(request: Request, handle: str | None = None):
    ctx = request.app.state.ctx
    hh = _household(request, handle)
    with Session(ctx.engine) as s:
        items = inventory.fresh_items(s, hh.id)
        soon = inventory.use_soon(s, hh.id, ctx.clock.now())
    if not items:
        return {"text": "Your fridge is empty right now."}
    names = list(dict.fromkeys(i.name for i in items))
    soon_names = list(dict.fromkeys(f"{i.name} {_say_day(copy.day_label(i.expires_at, ctx.clock))}" for i in soon))
    text = f"You have {len(items)} items."
    if soon_names:
        text += " Use soon: " + ", ".join(soon_names[:4]) + "."
    others = [n for n in names if n not in {i.name for i in soon}]
    if others:
        text += " Also " + ", ".join(others[:6]) + ("." if len(others) <= 6 else ", and more.")
    return {"text": text}


@router.get("/check")
async def check(request: Request, item: str, handle: str | None = None):
    ctx = request.app.state.ctx
    hh = _household(request, handle)
    label, units = check_units(ctx, hh.id, item)
    if not units:
        return {"text": f"You have no {label}. Want me to add {label} to your list?", "have": 0}
    when = _say_day(copy.day_label(units[0].expires_at, ctx.clock))
    count = f"{len(units)} " if len(units) > 1 else ""
    return {"text": f"Yes, you have {count}{label}. Use it {when}.", "have": len(units)}


class AddBody(BaseModel):
    item: str
    handle: str | None = None


@router.post("/list/add")
async def list_add(request: Request, body: AddBody, handle: str | None = None):
    ctx = request.app.state.ctx
    hh = _household(request, handle or body.handle)
    reply = add_to_list(ctx, hh.id, body.item)
    # Confirm over iMessage too, so the call leaves a written trace.
    await notify_household(ctx, hh.id, f"📞 From your call: {reply}",
                           f"voice:add:{body.item.lower()[:40]}:{ctx.clock.real_now().timestamp():.0f}")
    spoken = reply.replace("🛒 ", "")
    return {"text": spoken + " I also texted you."}


@router.get("/expiring")
async def expiring(request: Request, handle: str | None = None):
    """What to use soon, spoken."""
    ctx = request.app.state.ctx
    hh = _household(request, handle)
    with Session(ctx.engine) as s:
        soon = inventory.use_soon(s, hh.id, ctx.clock.now())
    if not soon:
        return {"text": "Nothing is about to expire. You're good for the next couple of days.", "count": 0}
    names = list(dict.fromkeys(f"{i.name} {_say_day(copy.day_label(i.expires_at, ctx.clock))}" for i in soon))
    return {"text": "Use these soon: " + ", ".join(names[:5]) + ". Want recipe ideas that use them?",
            "count": len(soon)}


@router.get("/recipes")
async def recipes_tool(request: Request, handle: str | None = None, item: str | None = None,
                       expiring: bool = True):
    """Up to 3 recipe names, spoken. With `item`, recipes with that ingredient; otherwise (by default)
    recipes that use what's about to expire. The full list is texted too, so a reply with a number
    shows the ingredients, like any RECIPES text."""
    from ..brain import pending, recipes
    from ..models import PendingAction
    ctx = request.app.state.ctx
    hh = _household(request, handle)
    with Session(ctx.engine) as s:
        before = s.exec(select(func.max(PendingAction.id)).where(PendingAction.household_id == hh.id)).first() or 0
    if item and item.strip():
        text = await recipes.suggest(ctx, hh.id, item.strip()[:40])
    elif expiring:
        text = await recipes.suggest_expiring(ctx, hh.id)
    else:
        text = await recipes.suggest(ctx, hh.id, None)
    with Session(ctx.engine) as s:
        a = pending.latest(s, hh.id, ("recipes",))
        shown = pending.payload(a).get("recipes", []) if a and a.id > before else []
    if not shown:
        return {"text": _speak(text.split("\n")[0]), "count": 0}
    await notify_household(ctx, hh.id, f"📞 From your call: {text}",
                           f"voice:recipes:{(item or '').lower()[:30]}:{ctx.clock.real_now().timestamp():.0f}")
    names = [r["name"] for r in shown]
    spoken = (names[0] if len(names) == 1 else ", ".join(names[:-1]) + ", or " + names[-1])
    return {"text": f"You could make {spoken}. I texted you the list. Reply with a number for the ingredients.",
            "count": len(names)}
