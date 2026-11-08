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

from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import HTMLResponse
from pydantic import BaseModel
from sqlmodel import Session

from .auth import app_caller, is_operator, require_demo_token
from .context import Ctx
from .households import member_by_handle, provision_household
from .models import Household, Member

log = logging.getLogger("signup")


def mask(handle: str | None) -> str:
    """For logs: enough to tell people apart, not enough to contact them."""
    h = handle or ""
    if "@" in h:
        name, _, domain = h.partition("@")
        return f"{name[:1]}…@{domain}"
    return f"…{h[-4:]}" if len(h) > 4 else "…"
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
        log.warning("line assignment failed for %s: %s", mask(handle), exc)
        msg = str(exc)
        if "403" in msg:
            return None, "The Photon API key needs the platforms:write permission to assign lines."
        if "402" in msg or "capacity" in msg.lower() or "seat" in msg.lower():
            return None, "No shared iMessage seats left on the Photon plan."
        return None, "Photon couldn't assign a line right now."


async def sign_up(ctx: Ctx, first: str, last: str | None, raw_handle: str,
                  app_invite_code: str | None = None, app_identity: str | None = None) -> SignupResult:
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
    wants_app = bool(app_identity or (app_invite_code and app_invite_code.strip()))
    if existing and wants_app:
        # Anyone can type a phone number, so an existing bank is only connected to an app user or an
        # app household after the phone's owner says YES over iMessage.
        app_linked, app_message = False, await _ask_owner(ctx, hh, member, app_identity, app_invite_code)
        return SignupResult(household=hh, member=member, line=line, line_error=error,
                            simulated=ctx.photon.is_mock, existing=existing,
                            app_linked=app_linked, app_link_message=app_message)
    if app_identity:
        remember_app_member(ctx, app_identity, hh.id)
    if app_invite_code and app_invite_code.strip():
        from .spacetime.bridge import join_app_household
        try:
            app_linked, app_message = await join_app_household(ctx, hh, app_invite_code)
        except Exception:
            log.exception("couldn't link household %s to an app household", hh.id)
            app_linked, app_message = False, "Couldn't reach the app's database to share the fridge."
    return SignupResult(household=hh, member=member, line=line, line_error=error,
                        simulated=ctx.photon.is_mock, existing=existing,
                        app_linked=app_linked, app_link_message=app_message)


async def _ask_owner(ctx: Ctx, hh: Household, member: Member, app_identity: str | None,
                     app_invite_code: str | None) -> str:
    from .brain import pending
    from .photon.outbound import notify_household
    if not member.welcomed or member.status != "active":
        return ("This number already has a bank. Text the DigiFridgey line from that phone first, then "
                "connect again.")
    with Session(ctx.engine) as s:
        pending.create(s, hh.id, "claim", {"identity": app_identity, "code": (app_invite_code or "").strip().upper(),
                                           "member_id": member.id}, ctx.clock.now())
        s.commit()
    await notify_household(ctx, hh.id, "🔐 Someone asked to connect this bank to the DigiFridgy app"
                           + (f" (fridge code {(app_invite_code or '').strip().upper()})" if app_invite_code else "")
                           + ". Was it you? Reply YES to connect, NO if not.",
                           f"claim:{hh.id}:{ctx.clock.real_now().timestamp():.0f}")
    return "This number already has a bank. Reply YES on that phone to connect it to the app."


async def confirm_claim(ctx: Ctx, household_id: int, payload: dict) -> str:
    """The phone's owner said YES to connecting their existing bank to the app."""
    with Session(ctx.engine) as s:
        hh = s.get(Household, household_id)
    if payload.get("identity"):
        remember_app_member(ctx, payload["identity"], household_id)
    if payload.get("code"):
        from .spacetime.bridge import join_app_household
        ok, message = await join_app_household(ctx, hh, payload["code"])
        return message
    return "🔗 Connected. The app can now see this bank."


def remember_app_member(ctx: Ctx, identity: str, household_id: int) -> bool:
    """The app user with this SpacetimeDB identity is this bank household (for settle-up). Never moves
    an identity that already belongs to another bank: that would let one roommate pay from another's."""
    from .models import AppMember
    from .money import norm_identity
    ident = norm_identity(identity)
    if not re.fullmatch(r"[0-9a-f]{16,128}", ident):
        return False
    with Session(ctx.engine) as s:
        row = s.get(AppMember, ident)
        if row is not None:
            if row.household_id != household_id:
                log.warning("app identity …%s already belongs to bank household %s", ident[-6:], row.household_id)
            return row.household_id == household_id
        s.add(AppMember(identity=ident, household_id=household_id))
        s.commit()
        return True


router = APIRouter()


class SignupBody(BaseModel):
    first_name: str
    last_name: str | None = None
    phone: str
    app_invite_code: str | None = None
    app_identity: str | None = None


@router.get("/signup", response_class=HTMLResponse)
async def signup_page() -> str:
    return (Path(__file__).parent / "demo" / "static" / "signup.html").read_text()


@router.post("/signup", dependencies=[Depends(require_demo_token)])  # each sign-up uses a Photon seat
async def signup(request: Request, body: SignupBody):
    ctx = request.app.state.ctx
    # The identity comes from the app's verified SpacetimeDB token; a body value is only trusted from
    # the operator (local demo), since anyone could type someone else's identity.
    caller = await app_caller(request, required=False)
    identity = caller.identity if caller else (body.app_identity if is_operator(request) else None)
    try:
        r = await sign_up(ctx, body.first_name, body.last_name, body.phone, body.app_invite_code, identity)
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
