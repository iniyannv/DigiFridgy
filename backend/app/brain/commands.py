"""Command handlers: one incoming iMessage -> state change -> one reply."""
from __future__ import annotations

import asyncio

import json
import logging

from sqlmodel import Session, select

from ..context import Ctx
from ..fridge import inventory
from ..fridge.matching import best_catalog_match, category_for, match_items
from ..households import household_for_new_member, member_by_handle, same_app_household
from ..models import Household, Item, Member, PendingAction, ProcessedPurchase, ShoppingListItem
from ..photon.client import Inbound
from ..photon.outbound import send_reply
from . import copy, pending
from .router import Intent, _norm, route

log = logging.getLogger("commands")


async def _typing(ctx: Ctx, m: Inbound) -> None:
    """Shows "…" while we work on a reply. Best effort: some platforms don't support it."""
    try:
        await ctx.photon.set_typing(m.space_id, m.agent_id, True)
    except Exception:
        pass


def _last_action_id(ctx: Ctx, household_id: int) -> int:
    from sqlmodel import func
    with Session(ctx.engine) as s:
        return s.exec(select(func.max(PendingAction.id)).where(PendingAction.household_id == household_id)).first() or 0


def _asked(ctx: Ctx, household_id: int, after: int) -> int | None:
    """The YES/NO question this reply asks, if handling the message opened one."""
    with Session(ctx.engine) as s:
        a = pending.latest(s, household_id, pending.YES_NO_KINDS)
        return a.id if a and a.id > after else None


async def _answer_content(ctx: Ctx, hh: Household, m: Inbound, intent: Intent, member: Member | None,
                          in_group: bool) -> str | None:
    """Photos and tapbacks first; everything else goes through the text commands."""
    if m.content_type == "reaction":
        from . import tapback
        return await tapback.handle(ctx, hh, m)
    if m.content_type == "attachment" and m.attachment_id:
        from . import photo
        return await photo.handle(ctx, hh, m)
    return await dispatch(ctx, hh, intent, member=member, in_group=in_group, text=m.text)


async def handle_message(ctx: Ctx, m: Inbound) -> None:
    if m.content_type in ("text", "attachment"):
        asyncio.create_task(_typing(ctx, m))
    if m.is_group:
        await handle_group_message(ctx, m)
        return
    intent = await route(m.text, ctx.llm) if m.text else Intent(name="not_text")
    # Same form as sign-up stores ("+14695550123"), so one person never becomes two members.
    from ..signup import normalize_handle
    handle = normalize_handle(m.sender_handle) or m.sender_handle
    with Session(ctx.engine) as s:
        member = member_by_handle(s, handle) or (member_by_handle(s, m.sender_handle)
                                                 if handle != m.sender_handle else None)

    if member is None:
        if intent.name == "stop":
            return
        from . import family
        with Session(ctx.engine) as s:
            inv = family.open_invite(s, handle)
            if inv is not None:  # someone in a household invited this number: they join it
                member = family.join(ctx, s, inv, handle, m.space_id, m.agent_id)
                hh = s.get(Household, member.household_id)
        if member is not None:
            await send_reply(ctx, member, m.id,
                             copy.invited_welcome(member.display_name, hh.name, family.inviter_name(ctx, member)))
            return
        hh = await household_for_new_member(ctx, handle)
        with Session(ctx.engine) as s:
            member = Member(household_id=hh.id, photon_handle=handle, photon_space_id=m.space_id,
                            agent_user_id=m.agent_id, welcomed=True, created_at=ctx.clock.now())
            s.add(member)
            s.commit()
            s.refresh(member)
        welcome = copy.welcome(hh.name, new=True)
        code = await _app_code(ctx, hh, announce=False)
        if code:
            from ..spacetime.bridge import app_invite_text
            welcome += "\n" + app_invite_text(code)
        await send_reply(ctx, member, m.id, welcome)
        return

    with Session(ctx.engine) as s:
        member = s.get(Member, member.id)
        if member.status == "stopped":
            if _norm(m.text or "") not in ("start", "unstop"):
                return  # STOP means silence until they text START (a "hi" doesn't opt them back in)
            member.status = "active"
        member.photon_space_id = m.space_id
        member.agent_user_id = m.agent_id
        first_text = not member.welcomed  # signed up on the web, texting for the first time
        member.welcomed = True
        s.add(member)
        s.commit()
        s.refresh(member)
        hh = s.get(Household, member.household_id)

    if first_text and intent.name != "stop":
        from . import family
        welcome = (copy.invited_welcome(member.display_name, hh.name, family.inviter_name(ctx, member))
                   if family.is_guest(ctx, member.id) else copy.welcome(hh.name, new=True))
        await send_reply(ctx, member, m.id, welcome)
        return

    if intent.name == "stop":
        await send_reply(ctx, member, m.id, copy.STOPPED)
        with Session(ctx.engine) as s:
            row = s.get(Member, member.id)
            row.status = "stopped"
            row.photon_space_id = None  # delete the conversation link
            s.add(row)
            others = s.exec(select(Member).where(Member.household_id == row.household_id, Member.id != row.id,
                                                 Member.status == "active")).first()
            # Nothing they were asked can be confirmed later: their questions (all of them when no
            # one else in the household is listening) are closed.
            pending.cancel_open(s, row.household_id, member.id if others else None)
            s.commit()
        return

    before = _last_action_id(ctx, hh.id)
    reply = await _answer_content(ctx, hh, m, intent, member, in_group=False)
    if reply:
        await send_reply(ctx, member, m.id, reply, action_id=_asked(ctx, hh.id, before))


async def handle_group_message(ctx: Ctx, m: Inbound) -> None:
    """The household group chat. The first member who texts in a new group links it to their household
    and I greet everyone in it by name; after that, any member's messages there act on that household and
    replies go to the whole group. An invited number joins on its first message there. Anyone else gets one
    short explanation and is then ignored. Money needs a YES in the account holder's own 1:1 chat."""
    from ..models import HouseholdSpace
    from ..photon.outbound import key_salt, post, reply_in
    from ..signup import normalize_handle
    from . import family
    from .router import keyword_intent
    handle = normalize_handle(m.sender_handle) or m.sender_handle
    joined = linked_now = False
    stranger_hh: Household | None = None
    own_hh: Household | None = None  # a roommate's own bank household, when it isn't the group's
    with Session(ctx.engine) as s:
        member = member_by_handle(s, handle) or (member_by_handle(s, m.sender_handle)
                                                 if handle != m.sender_handle else None)
        group = s.get(HouseholdSpace, m.space_id)
        if member is not None and member.status == "stopped":
            return
        if member is None:
            inv = family.open_invite(s, handle)
            if inv is not None and (group is None or group.household_id == inv.household_id):
                member = family.join(ctx, s, inv, handle)
                joined = True
        if member is None:
            stranger_hh = s.get(Household, group.household_id) if group else None
        elif group is None:
            group = HouseholdSpace(space_id=m.space_id, household_id=member.household_id,
                                   agent_user_id=m.agent_id, linked_at=ctx.clock.now())
            s.add(group)
            s.commit()
            hh = s.get(Household, member.household_id)
            linked_now = True
        else:
            # Roommates who connected their own card are their own bank household, but they share the
            # app fridge with the group's household, so they're in. Anyone else's number is ignored.
            if not same_app_household(s, group.household_id, member.household_id):
                return
            hh = s.get(Household, group.household_id)
            if member.household_id != hh.id:
                own_hh = s.get(Household, member.household_id)

    if member is None:
        said = keyword_intent(m.text or "") if m.content_type == "text" else None
        # A group nobody in a household has linked could be anyone's: stay quiet there.
        if stranger_hh is None or m.content_type == "reaction" or (said is not None and said.name == "stop"):
            return
        # Once per person per group: the send key doesn't change, so repeats are dropped.
        await post(ctx, m.space_id, m.agent_id, copy.stranger_in_group(stranger_hh.name),
                   f"{key_salt(ctx)}:stranger:{m.space_id}:{handle}"[:255], m.id, stranger_hh.id)
        return
    if linked_now:
        await reply_in(ctx, m.space_id, m.agent_id, m.id, await family.group_greeting(ctx, hh, m.space_id, member),
                       hh.id)
        return
    intent = await route(m.text, ctx.llm) if m.text else Intent(name="not_text")
    # The fridge and list are shared; a roommate's money (balance, budget, settle-up, app link) is their own.
    act_hh = own_hh if own_hh is not None and intent.name in OWN_BANK_INTENTS else hh
    before = _last_action_id(ctx, act_hh.id)
    if intent.name == "stop":
        reply = "To stop my messages, text STOP to me directly. Everyone else in this group keeps getting them."
    elif joined and intent.name in ("start", "help", "unknown", "not_text") and m.content_type != "attachment":
        reply = None
    else:
        reply = await _answer_content(ctx, act_hh, m, intent, member, in_group=True)
    if joined:
        hello = copy.invited_welcome(member.display_name, hh.name, family.inviter_name(ctx, member))
        reply = hello + ("\n\n" + reply if reply else "")
    if reply:
        await reply_in(ctx, m.space_id, m.agent_id, m.id, reply, act_hh.id,
                       action_id=_asked(ctx, act_hh.id, before))


# In the group chat, these act on the sender's own bank household when a roommate with their own card
# says them: everything else (fridge, list, claims, recipes, photos) is the shared fridge.
OWN_BANK_INTENTS = ("money", "settle", "budget", "trips", "app", "link")


async def dispatch(ctx: Ctx, hh: Household, intent: Intent, member: Member | None = None,
                   in_group: bool = False, text: str | None = None) -> str:
    member_id = member.id if member else None
    name = intent.name
    if name == "not_text":
        return copy.NOT_TEXT
    if name == "start":
        return copy.welcome(hh.name, new=False)
    if name == "help":
        return copy.HELP
    if name == "privacy":
        return copy.PRIVACY
    if name == "fridge":
        return fridge_text(ctx, hh.id)
    if name == "expiring":
        with Session(ctx.engine) as s:
            return copy.expiring(inventory.use_soon(s, hh.id, ctx.clock.now()), ctx.clock)
    if name in ("used", "tossed"):
        return update_item(ctx, hh.id, intent.item, name)
    if name == "choice":
        return answer_choice(ctx, hh.id, intent.choice or 0)
    if name in ("yes", "no"):
        return await answer_yes_no(ctx, hh, name == "yes", member_id=member_id, exact=intent.exact,
                                   allow_money=not in_group)
    if name in ("claim", "claim_last", "ask_claim"):
        from . import claims
        if name == "ask_claim":
            reply = claims.ask(ctx, hh, member, intent.item or "")
            if not in_group:  # nobody else sees a 1:1 chat, so ask the household
                from ..photon.outbound import notify_group
                await notify_group(ctx, hh.id, reply, f"ask:{hh.id}:{intent.item}:{ctx.clock.real_now().timestamp():.0f}")
            return reply
        return claims.claim(ctx, hh, member, intent.item if name == "claim" else None)
    if name == "list":
        return list_text(ctx, hh.id)
    if name == "add":
        return add_to_list(ctx, hh.id, intent.item or "")
    if name == "remove":
        return remove_from_list(ctx, hh.id, intent.item or "")
    if name == "add_all":
        return add_all(ctx, hh.id)
    if name == "money":
        return money_text(ctx, hh.id)
    if name in ("settle", "budget") and member is not None:
        from .family import is_guest
        if is_guest(ctx, member.id):
            return copy.GUEST_MONEY
    if name == "settle":
        from .. import money
        return await money.offer(ctx, hh, member_id=member_id)
    if name == "trips":
        return trips_text(ctx, hh.id)
    if name == "budget":
        if not intent.amount:
            return money_text(ctx, hh.id)
        with Session(ctx.engine) as s:
            row = s.get(Household, hh.id)
            row.weekly_budget = round(intent.amount, 2)
            s.add(row)
            s.commit()
        return copy.budget_set(intent.amount)
    if name == "dinner":
        from . import recipes
        return await recipes.suggest(ctx, hh.id, intent.item)
    if name == "ingredients":
        from . import recipes
        return recipes.ingredients_text(ctx, hh.id)
    if name in ("group", "invite", "name"):
        from . import family
        if name == "group":
            return await family.group_command(ctx, hh, member, in_group)
        if name == "invite":
            return family.invite(ctx, hh, member, intent.item or "", intent.person, in_group)
        return family.set_name(ctx, member, intent.item or "")
    if name == "check":
        return check_text(ctx, hh.id, intent.item or "")
    if name == "app":
        code = await _app_code(ctx, hh, announce=False)
        if not code:
            return copy.APP_OFF
        from ..spacetime.bridge import app_invite_text
        return app_invite_text(code)
    if name == "link":
        from ..spacetime.bridge import link_to_code
        return await link_to_code(ctx, hh, intent.item or "")
    if name == "unknown" and text and ctx.llm is not None:
        return await chat_reply(ctx, hh, text, in_group)
    return copy.UNKNOWN


def chat_facts(ctx: Ctx, household_id: int) -> dict:
    """What Gemini may know when it answers a free-form message: the fridge and the shopping list."""
    now = ctx.clock.now()
    with Session(ctx.engine) as s:
        fresh = inventory.fresh_items(s, household_id)
        soon = {i.id for i in inventory.use_soon(s, household_id, now)}
        rows = [r for r in _open_rows(s, household_id) if r.confirmed]
    fridge: dict[str, dict] = {}
    for it in fresh:  # ordered by expiry, so the first unit of a name is the one that goes first
        row = fridge.setdefault(it.name, {"name": it.name, "qty": 0, "where": it.location,
                                          "days_left": (ctx.clock.to_local(it.expires_at).date()
                                                        - ctx.clock.today()).days,
                                          "use_soon": it.id in soon})
        row["qty"] += 1
    return {"today": ctx.clock.today().isoformat(), "fridge": list(fridge.values())[:40],
            "shopping_list": [r.name for r in rows][:25]}


async def chat_reply(ctx: Ctx, hh: Household, text: str, in_group: bool) -> str:
    """Gemini answers what no command matched. It only writes text: nothing here changes state.
    In the group chat it stays quiet when people are talking to each other, not to me."""
    try:
        got = await ctx.llm.chat(text, chat_facts(ctx, hh.id), in_group=in_group)
    except Exception:
        log.exception("chat reply failed")
        got = None
    if not got:
        return copy.UNKNOWN
    if in_group and not got.get("for_me", True):
        return ""
    return got.get("reply") or copy.UNKNOWN


async def _app_code(ctx: Ctx, hh: Household, announce: bool) -> str | None:
    """The iPhone app invite code for this household (creates the app household on first use)."""
    if ctx.spacetime is None:
        return None
    from ..spacetime import bridge
    code = bridge.invite_code(ctx, hh.id)
    if code:
        return code
    try:
        link = await bridge.ensure_link(ctx, hh, announce=announce)
    except Exception:
        log.exception("couldn't create the app household for %s", hh.id)
        return None
    return link.invite_code or None


# ---------- fridge ----------

def fridge_text(ctx: Ctx, household_id: int) -> str:
    with Session(ctx.engine) as s:
        items = inventory.fresh_items(s, household_id)
        soon = {i.id for i in inventory.use_soon(s, household_id, ctx.clock.now())}
        return copy.fridge(items, ctx.clock, soon)


def _apply(ctx: Ctx, s: Session, household_id: int, items: list[Item], status: str) -> str:
    now = ctx.clock.now()
    name = items[0].name
    sku = items[0].sku
    wasted = inventory.mark(s, items, status, now)
    remaining = len([i for i in inventory.fresh_items(s, household_id) if i.sku == sku])
    week_waste = 0.0
    if status == "tossed":
        start, end = inventory.week_bounds(ctx.clock)
        week_waste = round(sum(w.amount for w in inventory.waste_between(s, household_id, start, end)), 2)
    msg = copy.marked(name, status, remaining, wasted, week_waste)
    suggestions = inventory.suggest_staples(s, household_id, now, only={sku}) if remaining == 0 else []
    if suggestions:
        pending.create(s, household_id, "add_suggestions", {"ids": [r.id for r in suggestions]}, now)
        msg += "\n" + copy.suggestions_prompt([r.name for r in suggestions]).replace(
            "Reply ADD ALL", "Reply YES or ADD ALL")
    s.commit()
    return msg


def update_item(ctx: Ctx, household_id: int, query: str | None, status: str) -> str:
    now = ctx.clock.now()
    with Session(ctx.engine) as s:
        fresh = inventory.fresh_items(s, household_id)
        if not query:
            # Bare USED/TOSSED answers the latest expiry nudge.
            a = pending.latest(s, household_id, ("nudge",))
            if a and not pending.is_expired(a, now):
                item = s.get(Item, pending.payload(a)["item_id"])
                pending.set_status(s, a, "done")
                if item and item.status == "fresh":
                    return _apply(ctx, s, household_id, [item], status)
            return f"Which item? For example: {status.upper()} milk"

        cat = category_for(query)
        if cat:
            in_cat = [i for i in fresh if i.category == cat]
            if not in_cat:
                return copy.not_in_fridge(query)
            if len(in_cat) == 1:
                return _apply(ctx, s, household_id, in_cat, status)
            names = sorted({i.name for i in in_cat})
            pending.create(s, household_id, "bulk_used",
                           {"ids": [i.id for i in in_cat], "status": status, "category": query}, now)
            s.commit()
            return copy.bulk_confirm(query, names).replace("as used", "as tossed" if status == "tossed" else "as used")

        cands = match_items(query, fresh)
        if not cands:
            return copy.not_in_fridge(query)
        if len(cands) == 1:
            # Oldest unit first (fresh_items is ordered by expiry).
            item = next(i for i in fresh if i.id in cands[0].ids)
            return _apply(ctx, s, household_id, [item], status)
        options = []
        for c in cands[:4]:
            first = next(i for i in fresh if i.id in c.ids)
            options.append({"name": first.name, "item_id": first.id,
                            "bought": ctx.clock.to_local(first.purchased_at).strftime("%a")})
        pending.create(s, household_id, "disambiguate", {"status": status, "options": options}, now)
        s.commit()
        return copy.disambiguate(query, [(o["name"], o["bought"]) for o in options])


def answer_choice(ctx: Ctx, household_id: int, n: int) -> str:
    now = ctx.clock.now()
    with Session(ctx.engine) as s:
        a = pending.latest(s, household_id, ("disambiguate", "photo_stock", "recipes"))
        if not a or pending.is_expired(a, now):
            return copy.nothing_pending()
        p = pending.payload(a)
        if a.kind == "recipes":
            from . import recipes
            return recipes.detail(ctx, s, household_id, p, n)
        if a.kind == "photo_stock":
            from . import photo
            new, gone = photo.drop(p, n)
            if gone is None:
                return f"Reply a number from 1 to {len(p['items'])} to drop it, or YES to add them."
            if not new["items"]:
                pending.set_status(s, a, "declined")
                s.commit()
                return f"👍 Dropped {gone}. Nothing left to add."
            a.payload_json = json.dumps(new)
            s.add(a)
            s.commit()
            return f"👍 Dropped {gone}.\n" + photo.render(new["kind"], new["items"])
        if not 1 <= n <= len(p["options"]):
            return f"Reply a number from 1 to {len(p['options'])}."
        pending.set_status(s, a, "done")
        item = s.get(Item, p["options"][n - 1]["item_id"])
        if not item or item.status != "fresh":
            s.commit()
            return "That item was already updated. Reply FRIDGE to check."
        return _apply(ctx, s, household_id, [item], p["status"])


async def answer_yes_no(ctx: Ctx, hh: Household, yes: bool, member_id: int | None = None,
                        exact: bool = True, action_id: int | None = None, allow_money: bool = True) -> str:
    """Answers the latest open question (or `action_id`). `exact`: the reply was the full word YES.
    Money moves only on that, and only for the member an offer was addressed to (when it was addressed
    to one). `allow_money=False` (group chats) refuses YES/NO on transfers: those need the account
    holder in their own chat or the app."""
    from ..nessie.banking import execute_transfer

    now = ctx.clock.now()
    with Session(ctx.engine) as s:
        if action_id is not None:
            a = s.get(PendingAction, action_id)
            if a is None or a.household_id != hh.id or a.status != "open":
                return "That question was already answered."
        else:
            money_q = pending.latest(s, hh.id, pending.MONEY_KINDS)
            other_q = pending.latest(s, hh.id, pending.OTHER_YES_NO_KINDS)
            if money_q and other_q:
                # Both open: YES answers the newer one; any other reply answers the fridge question.
                newest = max((money_q, other_q), key=lambda q: (q.created_at, q.id))
                a = newest if (yes and exact) else other_q
            else:
                a = money_q or other_q
        if not a:
            return copy.nothing_pending()
        if a.kind in pending.MONEY_KINDS and not allow_money:
            return "💳 Money only moves with a YES from the account holder, in their own chat with me or in the app."
        if pending.is_expired(a, now):
            pending.set_status(s, a, "expired")
            s.commit()
            return copy.offer_expired() if a.kind == "transfer" else "⌛ That question expired. Reply HELP for options."
        p = pending.payload(a)
        kind, action_id = a.kind, a.id
        owner = p.get("member_id")
        if kind in pending.MONEY_KINDS + ("claim",) and owner is not None and member_id is not None \
                and owner != member_id:
            return "That question was for someone else in your household, so I left it for them."
        if kind in pending.MONEY_KINDS and yes and not exact:
            return "To move money, reply with the full word YES (or NO to skip)."
        if kind in pending.MONEY_KINDS and yes and member_id is not None:
            from .family import is_guest
            if is_guest(ctx, member_id):
                return copy.GUEST_MONEY

        if kind == "recipe_missing":
            pending.set_status(s, a, "done" if yes else "declined")
            if not yes:
                s.commit()
                return "👍 OK, I left your list as it was."
            from . import recipes
            added = recipes.add_missing(ctx, s, hh.id, p)
            s.commit()
            return copy.added(added) if added else "🛒 Those are already on your list."

        if kind == "claim":
            pending.set_status(s, a, "done" if yes else "declined")
            s.commit()
            if not yes:
                return "👍 OK, nothing was connected. If that wasn't you, nobody can see your bank."

        if kind == "photo_stock":
            from . import photo
            if not yes:
                pending.set_status(s, a, "declined")
                s.commit()
                return "👍 OK, nothing added."
            pending.set_status(s, a, "done")
            fresh = [i for i in photo.stock(ctx, s, hh, p) if i.status == "fresh"]
            s.commit()
            names = sorted({i.name for i in fresh})
            return f"🧊 Added {len(fresh)} item{'s' if len(fresh) != 1 else ''}: {', '.join(names[:6])}" \
                + (" …" if len(names) > 6 else "") + ". They're in the app too."
        if kind == "settle":
            if not yes:
                pending.set_status(s, a, "declined")
                s.commit()
                return "👍 OK, nothing sent. Reply SETTLE anytime."
            s.commit()
        elif kind == "transfer":
            if not yes:
                pending.set_status(s, a, "declined")
                s.commit()
                return copy.transfer_declined()
            s.commit()
        elif kind == "bulk_used":
            pending.set_status(s, a, "done" if yes else "declined")
            if not yes:
                s.commit()
                return "👍 OK, I left them as they were."
            items = [i for i in (s.get(Item, iid) for iid in p["ids"]) if i and i.status == "fresh"]
            if not items:
                s.commit()
                return "Those were already updated."
            inventory.mark(s, items, p.get("status", "used"), now)
            s.commit()
            return copy.bulk_marked(len(items), p.get("category", ""), p.get("status", "used"))
        elif kind == "nudge":
            pending.set_status(s, a, "done")
            item = s.get(Item, p["item_id"])
            if not item or item.status != "fresh":
                s.commit()
                return "That item was already updated."
            if yes:
                s.commit()
                return copy.still_have_it(item.name)
            return _apply(ctx, s, hh.id, [item], "used")
        elif kind == "stock":
            from .. import card
            purchase_id = p["purchase_id"]
            record = s.get(ProcessedPurchase, purchase_id)
            if not yes:
                left = card.skip_rest(s, hh, purchase_id, now)
                s.commit()
                return copy.stock_declined(left)
            fresh = card.stock_lines(ctx, s, hh, purchase_id)
            s.commit()
            if not fresh:
                return "✅ Those items are already in your fridge."
            return copy.stocked(record.merchant_name if record else "the store",
                                sum(i.price for i in fresh), fresh, ctx.clock)
        elif kind == "add_suggestions":
            pending.set_status(s, a, "done" if yes else "declined")
            rows = [r for r in (s.get(ShoppingListItem, i) for i in p["ids"]) if r and not r.done]
            for r in rows:
                if yes:
                    r.confirmed = True
                else:
                    r.done = True
                s.add(r)
            s.commit()
            return copy.added([r.name for r in rows]) if yes and rows else "👍 OK, not adding it."

    if kind == "claim":
        from ..signup import confirm_claim
        return await confirm_claim(ctx, hh.id, p)

    # Money moves only here, after an explicit typed YES.
    if kind == "settle":
        from .. import money
        quoted = int(p["amount"]) if p.get("amount") else None
        return (await money.pay(ctx, p["app_household_id"], hh.id, int(p["to"]), action_id, quoted=quoted))[1]
    return await execute_transfer(ctx, hh, action_id, float(p["amount"]))


# ---------- shopping list ----------

def _open_rows(s: Session, household_id: int) -> list[ShoppingListItem]:
    return list(s.exec(select(ShoppingListItem).where(ShoppingListItem.household_id == household_id,
                                                      ShoppingListItem.done == False)  # noqa: E712
                       .order_by(ShoppingListItem.added_at)))


def list_text(ctx: Ctx, household_id: int) -> str:
    from .. import money
    from .claims import claims_for
    with Session(ctx.engine) as s:
        rows = _open_rows(s, household_id)
        active = [r for r in rows if r.confirmed]
        hh = s.get(Household, household_id)
        week_left = money.budget_streak(ctx, s, hh).week_left if hh and hh.checking_account_id else None
        return copy.shopping_list(active, [r for r in rows if not r.confirmed],
                                  money.list_estimate(s, household_id, active), week_left, claims_for(s, active))


def add_one(ctx: Ctx, s: Session, household_id: int, raw: str, source: str = "manual",
            sku: str | None = None) -> tuple[str, bool]:
    """Puts one thing on the list in this session. Returns (name shown, newly added)."""
    from ..fridge.shelf_life import is_known, lookup
    info = lookup(sku) if sku and is_known(sku) else best_catalog_match(raw)
    name = info.display_name if info else raw
    for r in _open_rows(s, household_id):
        if (info and r.sku == info.sku) or r.name.lower() == name.lower():
            if r.confirmed:
                return r.name, False
            r.confirmed = True
            s.add(r)
            return r.name, True
    s.add(ShoppingListItem(household_id=household_id, name=name, sku=info.sku if info else None,
                           source=source, confirmed=True, added_at=ctx.clock.now()))
    s.flush()
    return name, True


def add_to_list(ctx: Ctx, household_id: int, raw: str, source: str = "manual") -> str:
    raw = raw.strip()[:60]
    if not raw:
        return "What should I add? For example: ADD coffee"
    with Session(ctx.engine) as s:
        name, new = add_one(ctx, s, household_id, raw, source)
        s.commit()
    return copy.added([name]) if new else f"🛒 {name} is already on your list."


def remove_from_list(ctx: Ctx, household_id: int, raw: str) -> str:
    with Session(ctx.engine) as s:
        rows = _open_rows(s, household_id)
        cands = match_items(raw, rows)
        if not cands:
            return copy.not_on_list(raw)
        for r in rows:
            if r.id in cands[0].ids:
                r.done = True
                s.add(r)
        s.commit()
        return copy.removed(cands[0].name)


def add_all(ctx: Ctx, household_id: int) -> str:
    with Session(ctx.engine) as s:
        rows = [r for r in _open_rows(s, household_id) if not r.confirmed]
        if not rows:
            return "💡 No suggestions right now. Reply LIST to see your list."
        for r in rows:
            r.confirmed = True
            s.add(r)
        a = pending.latest(s, household_id, ("add_suggestions",))
        if a:
            pending.set_status(s, a, "done")
        s.commit()
        return copy.added([r.name for r in rows])


# ---------- money / check ----------

def money_text(ctx: Ctx, household_id: int) -> str:
    from .. import money
    from ..nessie.banking import insight
    with Session(ctx.engine) as s:
        hh = s.get(Household, household_id)
        text = copy.money(insight(ctx, s, hh))
        trips = money.recent_trips(ctx, s, household_id, limit=1)
        if trips:
            text += "\nLast trip: " + money.trip_line(trips[0])
        return text + "\n" + copy.streak_line(money.budget_streak(ctx, s, hh))


def trips_text(ctx: Ctx, household_id: int) -> str:
    from .. import money
    with Session(ctx.engine) as s:
        trips = money.recent_trips(ctx, s, household_id, limit=3)
    if not trips:
        return "🧾 No grocery card purchases in the last two weeks."
    return "🧾 Where your grocery money went\n" + "\n".join("• " + money.trip_line(t) for t in trips)


def check_units(ctx: Ctx, household_id: int, query: str) -> tuple[str, list[Item]]:
    with Session(ctx.engine) as s:
        fresh = inventory.fresh_items(s, household_id)
        cands = match_items(query, fresh)
        ids = {i for c in cands for i in c.ids}
        units = [i for i in fresh if i.id in ids]
    info = best_catalog_match(query)
    label = units[0].name if units else (info.display_name if info else query)
    return label, units


def check_text(ctx: Ctx, household_id: int, query: str) -> str:
    label, units = check_units(ctx, household_id, query)
    return copy.check(label, units, ctx.clock)
