"""Questions waiting on a YES, mirrored into SpacetimeDB's `approval` table so the app can answer
them too ("approve in either place"). The bridge posts them and acts on answers from the app;
answering by text closes them in the app."""
from __future__ import annotations

from sqlmodel import Session, select

from ..context import Ctx
from ..models import AppMember, CardPurchaseLine, Household, Item, PendingAction, ProcessedPurchase, \
    ShoppingListItem, SpacetimeLink
from . import pending

MONEY_KINDS = ("transfer", "settle")


def describe(s: Session, hh: Household, a: PendingAction) -> tuple[str, str, bool]:
    """(title, detail, moves money) for the app card."""
    from ..fridge.shelf_life import lookup
    from ..money import first_name
    p = pending.payload(a)
    owner = first_name(s, hh)
    if a.kind == "transfer":
        return (f"Move ${p.get('amount', 0):,.0f} to the Grocery Fund",
                f"From {owner}'s Everyday Checking: what's left of this week's grocery budget.", True)
    if a.kind == "settle":
        to = s.get(Household, int(p.get("to", 0)))
        return (f"{owner} pays {first_name(s, to) if to else 'a roommate'} ${p.get('amount', 0)}",
                f"From {owner}'s checking, for groceries they used.", True)
    if a.kind == "stock":
        rec = s.get(ProcessedPurchase, p.get("purchase_id", ""))
        lines = list(s.exec(select(CardPurchaseLine).where(
            CardPurchaseLine.nessie_purchase_id == p.get("purchase_id", ""), CardPurchaseLine.status == "pending")))
        names = ", ".join(lookup(r.sku).display_name for r in lines[:6])
        return (f"Add {len(lines)} items from {rec.merchant_name if rec else 'a card purchase'}", names, False)
    if a.kind == "photo_stock":
        items = p.get("items", [])
        return (f"Add {len(items)} item{'s' if len(items) != 1 else ''} from a photo",
                ", ".join(i["name"] for i in items[:8]), False)
    if a.kind == "add_suggestions":
        rows = [s.get(ShoppingListItem, i) for i in p.get("ids", [])]
        return ("Add to the shopping list?", ", ".join(r.name for r in rows if r), False)
    if a.kind == "nudge":
        item = s.get(Item, p.get("item_id", 0))
        name = item.name if item else "that item"
        return (f"Still have the {name}?", "Yes keeps it in the fridge. No marks it used.", False)
    return ("Confirm?", a.kind.replace("_", " "), False)


def decider(s: Session, identity_hex: str) -> tuple[int | None, str]:
    """Which bank household (if any) an app identity belongs to, and a name to show."""
    from ..money import first_name, norm_identity
    ident = norm_identity(identity_hex)
    m = s.get(AppMember, ident) if ident else None
    hh_id = m.household_id if m else None
    if hh_id is None:
        link = s.exec(select(SpacetimeLink).where(SpacetimeLink.identity == ident)).first() if ident else None
        hh_id = link.household_id if link else None
    hh = s.get(Household, hh_id) if hh_id else None
    return hh_id, (first_name(s, hh) if hh else "Someone")


async def apply_decision(ctx: Ctx, hh: Household, action_id: int, approve: bool,
                         identity_hex: str) -> tuple[bool, str]:
    """(handled, message for the household). Money questions only count from the account holder;
    otherwise (False, why) and the question goes back to open."""
    from .commands import answer_yes_no
    with Session(ctx.engine) as s:
        a = s.get(PendingAction, action_id)
        who_hh, who = decider(s, identity_hex)
        if a is None or a.status != "open":
            return True, ""
        if a.kind in MONEY_KINDS and who_hh != hh.id:
            from ..money import first_name
            return False, f"💳 Only {first_name(s, hh)} can approve moving their money, in the app or by text."
    reply = await answer_yes_no(ctx, hh, approve, action_id=action_id, allow_money=True)
    return True, f"📱 {who} said {'yes' if approve else 'no'} in the app. {reply}"
