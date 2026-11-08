"""Server tools for the ElevenLabs voice agent (calls arrive via Photon SIP).

Every request needs header `X-Tool-Secret: $VOICE_TOOL_SECRET`. Responses are
short sentences meant to be spoken (no emoji). In DEMO_MODE they act on the
demo household; otherwise pass ?handle=<caller's iMessage handle>.
"""
from __future__ import annotations

import hmac

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel
from sqlmodel import Session

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
    ctx = request.app.state.ctx
    with Session(ctx.engine) as s:
        if handle:
            m = member_by_handle(s, handle)
            if m:
                return s.get(Household, m.household_id)
        if ctx.settings.demo_mode:
            hh = demo_household(s)
            if hh:
                return hh
    raise HTTPException(404, "no household for this caller")


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
async def list_add(request: Request, body: AddBody):
    ctx = request.app.state.ctx
    hh = _household(request, body.handle)
    reply = add_to_list(ctx, hh.id, body.item)
    # Confirm over iMessage too, so the call leaves a written trace.
    await notify_household(ctx, hh.id, f"📞 From your call: {reply}",
                           f"voice:add:{body.item.lower()[:40]}:{ctx.clock.real_now().timestamp():.0f}")
    spoken = reply.replace("🛒 ", "")
    return {"text": spoken + " I also texted you."}
