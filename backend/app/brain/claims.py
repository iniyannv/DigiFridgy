"""Who's grabbing what: the household group chat (or anyone, by text) asks "who's grabbing milk?",
someone answers "I will", and the list remembers it. The app shows the same claim (`claimedBy` on the
shopping entry, synced through SpacetimeDB), and can claim too.
"""
from __future__ import annotations

from sqlmodel import Session, select

from ..context import Ctx
from ..fridge.matching import match_items
from ..models import Household, ListClaim, Member, ShoppingListItem
from . import pending


def member_name(member: Member | None) -> str:
    if member is None:
        return "Someone"
    if member.display_name:
        return member.display_name
    digits = "".join(ch for ch in member.photon_handle if ch.isdigit())
    return f"…{digits[-4:]}" if digits else member.photon_handle.split("@")[0]


def _open_rows(s: Session, household_id: int) -> list[ShoppingListItem]:
    return list(s.exec(select(ShoppingListItem).where(ShoppingListItem.household_id == household_id,
                                                      ShoppingListItem.done == False,  # noqa: E712
                                                      ShoppingListItem.confirmed == True)))  # noqa: E712


def _find(s: Session, household_id: int, item: str) -> ShoppingListItem | None:
    rows = _open_rows(s, household_id)
    cands = match_items(item, rows)
    if not cands:
        return None
    return s.get(ShoppingListItem, cands[0].ids[0])


def _ensure_row(ctx: Ctx, household_id: int, item: str) -> ShoppingListItem | None:
    from .commands import add_to_list
    with Session(ctx.engine) as s:
        row = _find(s, household_id, item)
    if row is None:
        add_to_list(ctx, household_id, item)
        with Session(ctx.engine) as s:
            row = _find(s, household_id, item)
    return row


def claims_for(s: Session, rows: list[ShoppingListItem]) -> dict[int, str]:
    ids = [r.id for r in rows]
    if not ids:
        return {}
    return {c.list_item_id: c.name for c in s.exec(select(ListClaim).where(ListClaim.list_item_id.in_(ids)))
            if c.name}


def ask(ctx: Ctx, hh: Household, member: Member | None, item: str) -> str:
    row = _ensure_row(ctx, hh.id, item)
    if row is None:
        return "What should someone grab? For example: who's grabbing milk?"
    with Session(ctx.engine) as s:
        claim = s.get(ListClaim, row.id)
        if claim and claim.name:
            return f"🙌 {claim.name} already said they'd grab {row.name}."
        pending.create(s, hh.id, "claim_q", {"row": row.id}, ctx.clock.now(), minutes=24 * 60)
        s.commit()
    return f"🛒 {member_name(member)} asks: who's grabbing {row.name}? Reply I WILL to take it."


def claim(ctx: Ctx, hh: Household, member: Member | None, item: str | None) -> str:
    now = ctx.clock.now()
    if item:
        row = _ensure_row(ctx, hh.id, item)
    else:
        with Session(ctx.engine) as s:
            a = pending.latest(s, hh.id, ("claim_q",))
            row = s.get(ShoppingListItem, pending.payload(a)["row"]) if a and not pending.is_expired(a, now) else None
            if row is not None and row.done:
                row = None
        if row is None:
            return "Grab what? For example: I'll get milk"
    name = member_name(member)
    with Session(ctx.engine) as s:
        existing = s.get(ListClaim, row.id)
        if existing and existing.name and existing.name != name and \
                (existing.member_id is None or member is None or existing.member_id != member.id):
            return f"🙌 {existing.name} already said they'd grab {row.name}."
        c = existing or ListClaim(list_item_id=row.id, claimed_at=now)
        c.name, c.member_id, c.claimed_at = name, member.id if member else None, now
        s.add(c)
        a = pending.latest(s, hh.id, ("claim_q",))
        if a and pending.payload(a).get("row") == row.id:
            pending.set_status(s, a, "done")
        s.commit()
    return f"🙌 {name}'s grabbing {row.name}. Check it off when it's in the fridge."
