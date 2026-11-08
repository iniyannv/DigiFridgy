"""Command handlers: one incoming iMessage -> state change -> one reply."""
from __future__ import annotations

import json
import logging
from pathlib import Path

from sqlmodel import Session, select

from ..context import Ctx
from ..fridge import inventory
from ..fridge.matching import best_catalog_match, category_for, match_items
from ..households import household_for_new_member, member_by_handle
from ..models import Household, Item, Member, ProcessedPurchase, ShoppingListItem
from ..photon.client import Inbound
from ..photon.outbound import send_reply
from . import copy, pending
from .router import Intent, _norm, route

log = logging.getLogger("commands")
RECIPES = json.loads(Path(__file__).with_name("recipes.json").read_text())


async def handle_message(ctx: Ctx, m: Inbound) -> None:
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
        await send_reply(ctx, member, m.id, copy.welcome(hh.name, new=True))
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

    reply = await dispatch(ctx, hh, intent, member.id)
    if reply:
        await send_reply(ctx, member, m.id, reply)


async def dispatch(ctx: Ctx, hh: Household, intent: Intent, member_id: int | None = None) -> str:
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
        return await answer_yes_no(ctx, hh, name == "yes", member_id=member_id, exact=intent.exact)
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
        a = pending.latest(s, household_id, ("disambiguate",))
        if not a or pending.is_expired(a, now):
            return copy.nothing_pending()
        p = pending.payload(a)
        if not 1 <= n <= len(p["options"]):
            return f"Reply a number from 1 to {len(p['options'])}."
        pending.set_status(s, a, "done")
        item = s.get(Item, p["options"][n - 1]["item_id"])
        if not item or item.status != "fresh":
            s.commit()
            return "That item was already updated. Reply FRIDGE to check."
        return _apply(ctx, s, household_id, [item], p["status"])


async def answer_yes_no(ctx: Ctx, hh: Household, yes: bool, member_id: int | None = None,
                        exact: bool = True) -> str:
    """`exact`: the reply was the full word YES. Money moves only on that, and only for the member an
    offer was addressed to (when it was addressed to one)."""
    from ..nessie.banking import execute_transfer

    now = ctx.clock.now()
    with Session(ctx.engine) as s:
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

        if kind == "claim":
            pending.set_status(s, a, "done" if yes else "declined")
            s.commit()
            if not yes:
                return "👍 OK, nothing was connected. If that wasn't you, nobody can see your bank."

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
    with Session(ctx.engine) as s:
        rows = _open_rows(s, household_id)
        active = [r for r in rows if r.confirmed]
        hh = s.get(Household, household_id)
        week_left = money.budget_streak(ctx, s, hh).week_left if hh and hh.checking_account_id else None
        return copy.shopping_list(active, [r for r in rows if not r.confirmed],
                                  money.list_estimate(s, household_id, active), week_left)


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
