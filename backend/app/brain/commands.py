"""Command handlers: one incoming iMessage -> state change -> one reply."""
from __future__ import annotations

import asyncio

import json
import logging
from pathlib import Path

from sqlmodel import Session, select

from ..context import Ctx
from ..fridge import inventory
from ..fridge.matching import best_catalog_match, category_for, match_items
from ..households import household_for_new_member, member_by_handle
from ..models import Household, Item, Member, PendingAction, ProcessedPurchase, ShoppingListItem
from ..photon.client import Inbound
from ..photon.outbound import send_reply
from . import copy, pending
from .router import Intent, route

log = logging.getLogger("commands")
RECIPES = json.loads(Path(__file__).with_name("recipes.json").read_text())


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
    return await dispatch(ctx, hh, intent, member=member, in_group=in_group)


async def handle_message(ctx: Ctx, m: Inbound) -> None:
    if m.content_type in ("text", "attachment"):
        asyncio.create_task(_typing(ctx, m))
    if m.is_group:
        await handle_group_message(ctx, m)
        return
    intent = await route(m.text, ctx.llm) if m.text else Intent(name="not_text")
    with Session(ctx.engine) as s:
        member = member_by_handle(s, m.sender_handle)

    if member is None:
        if intent.name == "stop":
            return
        hh = await household_for_new_member(ctx, m.sender_handle)
        with Session(ctx.engine) as s:
            member = Member(household_id=hh.id, photon_handle=m.sender_handle, photon_space_id=m.space_id,
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
            if intent.name != "start":
                return  # STOP means silence until they opt back in
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
        await send_reply(ctx, member, m.id, copy.welcome(hh.name, new=True))
        return

    if intent.name == "stop":
        await send_reply(ctx, member, m.id, copy.STOPPED)
        with Session(ctx.engine) as s:
            row = s.get(Member, member.id)
            row.status = "stopped"
            row.photon_space_id = None  # delete the conversation link
            s.add(row)
            s.commit()
        return

    before = _last_action_id(ctx, hh.id)
    reply = await _answer_content(ctx, hh, m, intent, member, in_group=False)
    if reply:
        await send_reply(ctx, member, m.id, reply, action_id=_asked(ctx, hh.id, before))

async def handle_group_message(ctx: Ctx, m: Inbound) -> None:
    """The household group chat. The first member who texts in a new group links it to their household;
    after that, any member's messages there act on that household and replies go to the whole group.
    People I don't know are ignored, and money needs a YES in the account holder's own 1:1 chat."""
    from ..models import HouseholdSpace
    from ..photon.outbound import reply_in
    with Session(ctx.engine) as s:
        member = member_by_handle(s, m.sender_handle)
        group = s.get(HouseholdSpace, m.space_id)
        if member is None or member.status == "stopped":
            return
        if group is None:
            group = HouseholdSpace(space_id=m.space_id, household_id=member.household_id,
                                   agent_user_id=m.agent_id, linked_at=ctx.clock.now())
            s.add(group)
            s.commit()
            hh = s.get(Household, member.household_id)
            linked_now = True
        else:
            if group.household_id != member.household_id:
                return
            hh = s.get(Household, group.household_id)
            linked_now = False
    if linked_now:
        await reply_in(ctx, m.space_id, m.agent_id, m.id, copy.group_welcome(hh.name), hh.id)
        return
    intent = await route(m.text, ctx.llm) if m.text else Intent(name="not_text")
    before = _last_action_id(ctx, hh.id)
    if intent.name == "stop":
        reply = "To stop my messages, text STOP to me directly. Everyone else in this group keeps getting them."
    else:
        reply = await _answer_content(ctx, hh, m, intent, member, in_group=True)
    if reply:
        await reply_in(ctx, m.space_id, m.agent_id, m.id, reply, hh.id, action_id=_asked(ctx, hh.id, before))


async def dispatch(ctx: Ctx, hh: Household, intent: Intent, member: Member | None = None,
                   in_group: bool = False) -> str:
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
        return await answer_yes_no(ctx, hh, name == "yes", allow_money=not in_group)
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
    if name == "settle":
        from .. import money
        return await money.offer(ctx, hh)
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
        return copy.dinner(await dinner_ideas(ctx, hh.id))
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
    return copy.UNKNOWN


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
        a = pending.latest(s, household_id, ("disambiguate", "photo_stock"))
        if not a or pending.is_expired(a, now):
            return copy.nothing_pending()
        p = pending.payload(a)
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


async def answer_yes_no(ctx: Ctx, hh: Household, yes: bool, action_id: int | None = None,
                        allow_money: bool = True) -> str:
    """Answers the latest open question (or `action_id`). `allow_money=False` (group chats) refuses
    YES/NO on transfers: those need the account holder in their own chat or the app."""
    from ..nessie.banking import execute_transfer

    now = ctx.clock.now()
    with Session(ctx.engine) as s:
        if action_id is not None:
            a = s.get(PendingAction, action_id)
            if a is None or a.household_id != hh.id or a.status != "open":
                return "That question was already answered."
        else:
            a = pending.latest(s, hh.id, pending.YES_NO_KINDS)
        if not a:
            return copy.nothing_pending()
        if a.kind in ("transfer", "settle") and not allow_money:
            return "💳 Money only moves with a YES from the account holder, in their own chat with me or in the app."
        if pending.is_expired(a, now):
            pending.set_status(s, a, "expired")
            s.commit()
            return copy.offer_expired() if a.kind == "transfer" else "⌛ That question expired. Reply HELP for options."
        p = pending.payload(a)
        kind, action_id = a.kind, a.id

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

    # Money moves only here, after an explicit typed YES.
    if kind == "settle":
        from .. import money
        return (await money.pay(ctx, p["app_household_id"], hh.id, int(p["to"]), action_id))[1]
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


def add_to_list(ctx: Ctx, household_id: int, raw: str, source: str = "manual") -> str:
    raw = raw.strip()[:60]
    if not raw:
        return "What should I add? For example: ADD coffee"
    info = best_catalog_match(raw)
    name = info.display_name if info else raw
    with Session(ctx.engine) as s:
        for r in _open_rows(s, household_id):
            if (info and r.sku == info.sku) or r.name.lower() == name.lower():
                if r.confirmed:
                    return f"🛒 {r.name} is already on your list."
                r.confirmed = True
                s.add(r)
                s.commit()
                return copy.added([r.name])
        s.add(ShoppingListItem(household_id=household_id, name=name, sku=info.sku if info else None,
                               source=source, confirmed=True, added_at=ctx.clock.now()))
        s.commit()
    return copy.added([name])


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


# ---------- money / dinner / check ----------

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


def template_ideas(use_soon_skus: list[str], fresh_skus: set[str]) -> list[str]:
    scored = []
    for r in RECIPES:
        uses = set(r["uses"])
        soon_hits = [sku for sku in use_soon_skus if sku in uses]
        have_hits = uses & fresh_skus
        score = 10 * len(soon_hits) + len(have_hits)
        if soon_hits or len(have_hits) >= 2:
            scored.append((score, r["name"]))
    scored.sort(key=lambda x: -x[0])
    return [name for _, name in scored[:2]]


async def dinner_ideas(ctx: Ctx, household_id: int) -> list[str]:
    with Session(ctx.engine) as s:
        fresh = inventory.fresh_items(s, household_id)
        soon = inventory.use_soon(s, household_id, ctx.clock.now())
    soon_skus = list(dict.fromkeys(i.sku for i in soon))
    if ctx.llm is not None and fresh:
        ideas = await ctx.llm.dinner_ideas([i.name for i in soon], sorted({i.name for i in fresh}))
        if ideas:
            return ideas
    ideas = template_ideas(soon_skus, {i.sku for i in fresh})
    return ideas or ["Your fridge is light. Reply LIST to plan a grocery run."]


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
