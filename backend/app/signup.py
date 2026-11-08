"""Web sign-up: name + phone number -> household (own synthetic Nessie customer
and accounts) + a Photon shared iMessage line assigned to that phone number.

Photon shared lines can't send the first message, so sign-up ends with
"text <number> to start". The first text links the conversation.
"""
from __future__ import annotations

import logging
import re
from dataclasses import dataclass
from pathlib import Path

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import HTMLResponse
from pydantic import BaseModel
from sqlmodel import Session

from .context import Ctx
from .households import member_by_handle, provision_household
from .models import Household, Member

log = logging.getLogger("signup")
E164 = re.compile(r"^\+[1-9]\d{6,14}$")
EMAIL = re.compile(r"^[^@\s]+@[^@\s]+\.[A-Za-z]{2,}$")


def normalize_handle(raw: str) -> str | None:
    """US-friendly: '(469) 555-0123' -> '+14695550123'. Apple ID emails are allowed too."""
    raw = (raw or "").strip()
    if "@" in raw:
        return raw.lower() if EMAIL.match(raw) else None
    digits = re.sub(r"\D", "", raw)
    if raw.startswith("+"):
        cand = "+" + digits
    elif len(digits) == 10:
        cand = "+1" + digits
    elif len(digits) == 11 and digits.startswith("1"):
        cand = "+" + digits
    else:
        return None
    return cand if E164.match(cand) else None


@dataclass
class SignupResult:
    household: Household
    member: Member
    line: str | None
    line_error: str | None
    simulated: bool
    existing: bool
    app_linked: bool | None = None   # None: no app invite code was given
    app_link_message: str | None = None


async def assign_line(ctx: Ctx, handle: str, first: str, last: str | None) -> tuple[str | None, str | None]:
    """Returns (assigned number, error). Reuses an active assignment for this handle."""
    try:
        for a in await ctx.photon.list_assignments():
            if a.get("handle") == handle and not a.get("releasedAt") and a.get("assignedPhoneNumber"):
                return a["assignedPhoneNumber"], None
    except Exception as exc:  # listing needs platforms:read; assignment may still work
        log.info("could not list assignments: %s", exc)
    try:
        a = await ctx.photon.assign_line(handle, f"digifridgey-signup:{handle}"[:255], first, last)
        return a.get("assignedPhoneNumber"), None
    except Exception as exc:
        log.warning("line assignment failed for %s: %s", handle, exc)
        msg = str(exc)
        if "403" in msg:
            return None, "The Photon API key needs the platforms:write permission to assign lines."
        if "402" in msg or "capacity" in msg.lower() or "seat" in msg.lower():
            return None, "No shared iMessage seats left on the Photon plan."
        return None, "Photon couldn't assign a line right now."


async def sign_up(ctx: Ctx, first: str, last: str | None, raw_handle: str,
                  app_invite_code: str | None = None) -> SignupResult:
    """`app_invite_code` comes from the iPhone app: the bank household then shares that app
    household's fridge instead of getting one of its own."""
    from .demo.seed import seed_history

    handle = normalize_handle(raw_handle)
    if not handle:
        raise ValueError("Enter a US phone number like (469) 555-0123, a +country number, or an Apple ID email.")
    first = first.strip()[:40] or "Friend"
    last = (last or "").strip()[:40] or None

    with Session(ctx.engine) as s:
        member = member_by_handle(s, handle)
        hh = s.get(Household, member.household_id) if member else None
    existing = member is not None

    if not existing:
        tail = re.sub(r"\D", "", handle)[-4:] or handle.split("@")[0][:4]
        hh = await provision_household(ctx, f"{first}'s Household ({tail})", first, last or "Fridge",
                                       is_demo=False, key=f"household:{handle}", lookup_by_name=False)
        if ctx.settings.demo_mode:
            await seed_history(ctx, hh)  # gives MONEY and trends something to show
        with Session(ctx.engine) as s:
            member = Member(household_id=hh.id, photon_handle=handle, display_name=first,
                            welcomed=False, created_at=ctx.clock.now())
            s.add(member)
            s.commit()
            s.refresh(member)

    line, error = member.assigned_line, None
    if not line:
        line, error = await assign_line(ctx, handle, first, last)
        if line:
            with Session(ctx.engine) as s:
                row = s.get(Member, member.id)
                row.assigned_line = line
                s.add(row)
                s.commit()
                s.refresh(row)
                member = row
    if not line and ctx.settings.photon_agent_handle:
        # Fallback: the configured line works if this number was added in the Photon dashboard.
        line = ctx.settings.photon_agent_handle
    app_linked = app_message = None
    if app_invite_code and app_invite_code.strip():
        from .spacetime.bridge import join_app_household
        try:
            app_linked, app_message = await join_app_household(ctx, hh, app_invite_code)
        except Exception:
            log.exception("couldn't link household %s to app household %s", hh.id, app_invite_code)
            app_linked, app_message = False, "Couldn't reach the app's database to share the fridge."
    return SignupResult(household=hh, member=member, line=line, line_error=error,
                        simulated=ctx.photon.is_mock, existing=existing,
                        app_linked=app_linked, app_link_message=app_message)


router = APIRouter()


class SignupBody(BaseModel):
    first_name: str
    last_name: str | None = None
    phone: str
    app_invite_code: str | None = None


@router.get("/signup", response_class=HTMLResponse)
async def signup_page() -> str:
    return (Path(__file__).parent / "demo" / "static" / "signup.html").read_text()


@router.post("/signup")
async def signup(request: Request, body: SignupBody):
    ctx = request.app.state.ctx
    token = ctx.settings.demo_token
    if token:  # each sign-up uses a Photon seat, so guard it like the demo controls
        import hmac
        given = request.headers.get("x-demo-token") or request.query_params.get("token") or ""
        if not hmac.compare_digest(given, token):
            raise HTTPException(401, "This server needs the app's access token.")
    try:
        r = await sign_up(ctx, body.first_name, body.last_name, body.phone, body.app_invite_code)
    except ValueError as exc:
        raise HTTPException(400, str(exc))
    return {
        "household": r.household.name,
        "household_id": r.household.id,
        "handle": r.member.photon_handle,
        "text_this_number": r.line,
        "line_error": r.line_error,
        "simulated": r.simulated,
        "existing": r.existing,
        "app_linked": r.app_linked,
        "app_link_message": r.app_link_message,
    }
