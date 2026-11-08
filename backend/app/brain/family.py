"""Family group chat: getting a household into one iMessage group with the agent.

Group chats need a dedicated (project-owned) line: GROUP creates the group there, and the first message
in a group links it to the household and greets everyone in it by name. Shared lines, which sign-up
assigns, can't start a chat and never receive messages sent in a group (checked live: Photon has no
record of them), so on a shared line GROUP says so and everyone texts the agent 1:1 instead.

INVITE <number> adds someone to the household before they've texted. Invited people are guests: they
share the fridge, list and group chat, but can't start or approve money moves.
"""
from __future__ import annotations

import hashlib
import logging

from sqlmodel import Session, func, select

from ..context import Ctx
from ..models import Household, HouseholdInvite, HouseholdSpace, Member
from . import copy

log = logging.getLogger("family")

MAX_OPEN_INVITES = 8


def label(m: Member | None, handle: str | None = None) -> str:
    if m is not None and m.display_name:
        return m.display_name
    return copy.pretty_handle(handle or (m.photon_handle if m else ""))


def is_guest(ctx: Ctx, member_id: int | None) -> bool:
    if member_id is None:
        return False
    with Session(ctx.engine) as s:
        return s.exec(select(HouseholdInvite).where(HouseholdInvite.member_id == member_id)).first() is not None


def open_invite(s: Session, handle: str) -> HouseholdInvite | None:
    inv = s.get(HouseholdInvite, handle)
    return inv if inv is not None and inv.member_id is None else None


def join(ctx: Ctx, s: Session, inv: HouseholdInvite, handle: str, space_id: str | None = None,
         agent_id: str | None = None) -> Member:
    """An invited person's first message: they become a member of the inviting household."""
    m = Member(household_id=inv.household_id, photon_handle=handle, display_name=inv.name,
               photon_space_id=space_id, agent_user_id=agent_id, welcomed=space_id is not None,
               created_at=ctx.clock.now())
    s.add(m)
    s.flush()
    inv.member_id = m.id
    s.add(inv)
    s.commit()
    s.refresh(m)
    return m


def inviter_name(ctx: Ctx, member: Member) -> str | None:
    with Session(ctx.engine) as s:
        inv = s.exec(select(HouseholdInvite).where(HouseholdInvite.member_id == member.id)).first()
        by = s.get(Member, inv.invited_by) if inv and inv.invited_by else None
        return label(by) if by else None


def _agent_number(ctx: Ctx, member: Member | None) -> str | None:
    return (member.assigned_line if member else None) or ctx.settings.photon_agent_handle or None


def _active_members(s: Session, hh_id: int) -> list[Member]:
    """Active members of this household, then of roommates' households (their own card, same app fridge)."""
    from ..households import linked_household_ids
    ids = linked_household_ids(s, hh_id)
    rows = list(s.exec(select(Member).where(Member.household_id.in_(ids), Member.status == "active")
                       .order_by(Member.id)))
    return sorted(rows, key=lambda m: (ids.index(m.household_id), m.id))


def _others(s: Session, hh_id: int, me: Member | None) -> list[tuple[str | None, str]]:
    """(name, handle) for everyone else sharing the fridge: active members (roommates with their own
    card included), then open invites."""
    out = []
    for m in _active_members(s, hh_id):
        if me is None or m.id != me.id:
            out.append((m.display_name, m.photon_handle))
    for inv in s.exec(select(HouseholdInvite).where(HouseholdInvite.household_id == hh_id,
                                                    HouseholdInvite.member_id == None)  # noqa: E711
                      .order_by(HouseholdInvite.created_at)):
        out.append((inv.name, inv.handle))
    return out


def _can_group(ctx: Ctx) -> bool:
    """Only a dedicated line can be in a group chat (shared lines never receive group messages)."""
    return bool(ctx.settings.photon_dedicated_line)


def _has_group(s: Session, hh_id: int) -> bool:
    return s.exec(select(HouseholdSpace).where(HouseholdSpace.household_id == hh_id)).first() is not None


def invite(ctx: Ctx, hh: Household, member: Member | None, raw: str, person: str | None,
           in_group: bool = False) -> str:
    from ..households import member_by_handle
    from ..signup import normalize_handle
    handle = normalize_handle(raw)
    if not handle or "@" in handle:
        return "🤔 That doesn't look like a phone number. Try: INVITE Mom (469) 555-0123"
    if member is not None and handle == member.photon_handle:
        return "🙂 That's your number. Text INVITE with someone else's number to add them."
    person = (person or "").strip()[:30] or None
    with Session(ctx.engine) as s:
        existing = member_by_handle(s, handle)
        if existing is not None:
            from ..households import same_app_household
            if existing.household_id == hh.id:
                tail = " Text GROUP to get everyone in one chat." if _can_group(ctx) else ""
                return f"✅ {label(existing)} is already in {hh.name}.{tail}"
            if same_app_household(s, existing.household_id, hh.id):
                # A roommate who connected their own card: they already share this fridge.
                where = "this group" if in_group else "your shared fridge"
                return f"✅ {label(existing)} is already in {where}: their own card shares the same fridge."
            return "That number already has its own DigiFridgy household, so I can't add it to yours."
        inv = s.get(HouseholdInvite, handle)
        if inv is not None and inv.household_id != hh.id:
            return "That number was already invited to another household, so I left it alone."
        if inv is None:
            waiting = s.exec(select(func.count()).select_from(HouseholdInvite).where(
                HouseholdInvite.household_id == hh.id, HouseholdInvite.member_id == None)).one()  # noqa: E711
            if waiting >= MAX_OPEN_INVITES:
                return f"You already have {waiting} invites waiting. Ask them to text me first."
            inv = HouseholdInvite(handle=handle, household_id=hh.id, created_at=ctx.clock.now())
        inv.name = person or inv.name
        inv.invited_by = member.id if member else inv.invited_by
        s.add(inv)
        s.commit()
        has_group = in_group or _has_group(s, hh.id)
        name = inv.name
    return copy.invited(name, handle, hh.name, _agent_number(ctx, member), has_group, _can_group(ctx))


def set_name(ctx: Ctx, member: Member | None, raw: str) -> str:
    name = raw.strip().title()[:20]
    if member is None or not name:
        return "What should I call you? For example: CALL ME Sam"
    with Session(ctx.engine) as s:
        row = s.get(Member, member.id)
        row.display_name = name
        s.add(row)
        s.commit()
    return copy.name_set(name)


async def group_command(ctx: Ctx, hh: Household, member: Member | None, in_group: bool) -> str:
    """GROUP: start the household group chat (dedicated line). On a shared line, explain that groups
    don't work there and everyone texts the agent 1:1."""
    with Session(ctx.engine) as s:
        others = _others(s, hh.id, member)
        if in_group:
            names = [label(m) for m in _active_members(s, hh.id)]
            return copy.group_already(hh.name, names)
    if not _can_group(ctx):
        return copy.group_unavailable(others, _agent_number(ctx, member))
    if others and member is not None and member.agent_user_id:
        created = await _create_group(ctx, hh, member, others)
        if created:
            return created
    # A dedicated line that couldn't create it (Photon refused, or nobody else yet): start it by hand.
    return copy.group_instructions(hh.name, others, _agent_number(ctx, member))


async def _create_group(ctx: Ctx, hh: Household, member: Member, others: list[tuple[str | None, str]]) -> str | None:
    from ..photon.outbound import key_salt, post
    handles = [member.photon_handle] + [h for _, h in others]
    digest = hashlib.sha256(",".join(sorted(handles)).encode()).hexdigest()[:16]
    try:
        space = await ctx.photon.create_group(member.agent_user_id, handles, f"{key_salt(ctx)}:group:{hh.id}:{digest}",
                                              ctx.settings.photon_platform)
    except Exception as exc:
        log.warning("couldn't start a group chat for household %s: %s", hh.id, exc)
        return None
    space_id = space.get("id") if isinstance(space, dict) else None
    if not space_id:
        return None
    with Session(ctx.engine) as s:
        if s.get(HouseholdSpace, space_id) is None:
            s.add(HouseholdSpace(space_id=space_id, household_id=hh.id, agent_user_id=member.agent_user_id,
                                 linked_at=ctx.clock.now()))
            s.commit()
    people = [label(member)] + [n or copy.pretty_handle(h) for n, h in others]
    await post(ctx, space_id, member.agent_user_id, copy.group_welcome(hh.name, people),
               f"{key_salt(ctx)}:groupwelcome:{space_id}"[:255], None, hh.id)
    return copy.group_created(people[1:])


async def group_greeting(ctx: Ctx, hh: Household, space_id: str, linker: Member) -> str:
    """The first message in a newly linked group: hello to everyone in it by name, and a note about
    numbers that aren't in the household yet."""
    handles: list[str] = []
    try:
        handles = await ctx.photon.space_handles(space_id) if hasattr(ctx.photon, "space_handles") else []
    except Exception as exc:
        log.info("couldn't list the people in group %s: %s", space_id, exc)
    from ..signup import normalize_handle
    with Session(ctx.engine) as s:
        by_handle = {m.photon_handle: m for m in _active_members(s, hh.id)}
        invites = {i.handle: i for i in s.exec(select(HouseholdInvite).where(
            HouseholdInvite.household_id == hh.id, HouseholdInvite.member_id == None))}  # noqa: E711
    people, strangers = [label(linker)], []
    for raw in handles:
        h = normalize_handle(raw) or raw
        if h == linker.photon_handle or h == ctx.settings.photon_agent_handle:
            continue
        if h in by_handle:
            people.append(label(by_handle[h]))
        elif h in invites:
            people.append(invites[h].name or copy.pretty_handle(h))
        else:
            strangers.append(h)
    return copy.group_welcome(hh.name, list(dict.fromkeys(people)), strangers)
