"""Grocery money, reimagined from the bank's side:

- `purchase_breakdown`: what happened to each card purchase: eaten, wasted, still in the fridge.
- `budget_streak`: weeks in a row under the grocery budget, and what was saved to the Grocery Fund.
- `list_estimate`: what the shopping list will cost, from what this household actually paid.
- Settle-up: roommates are bank households that share one app household (SpacetimeDB). Each card
  purchase knows who paid; SpacetimeDB's `item_use` log (app −1 taps) and the local `UsageLog`
  (USED over iMessage) say who ate it. A roommate who ate someone else's groceries owes them; paying
  is a Nessie transfer between their checking accounts, and only after a YES (or a tap in the app).
"""
from __future__ import annotations

import asyncio
import logging
from collections import defaultdict
from dataclasses import dataclass, field
from datetime import date, timedelta

from sqlmodel import Session, func, select

from .context import Ctx
from .models import (AppMember, CardPurchaseLine, Household, Item, Member, PendingAction, ProcessedPurchase,
                     Settlement, ShoppingListItem, SpaceItemLink, SpacetimeLink, UsageLog)
from .nessie.banking import grocery_spend
from .nessie.client import whole_dollars

log = logging.getLogger("money")

WASTED = ("expired", "tossed")


# ---------- what happened to each purchase ----------

def purchase_breakdown(s: Session, household_id: int, purchase_id: str, amount: float) -> dict:
    """Splits a card purchase into eaten / wasted / in the fridge / not added (never stocked) / other
    (tax and anything not itemized). The buckets add up to the charged amount."""
    units = list(s.exec(select(Item).where(Item.household_id == household_id,
                                           Item.source_purchase_id == purchase_id)))
    buckets = {"eaten": 0.0, "wasted": 0.0, "in_fridge": 0.0, "not_added": 0.0}
    names: dict[str, list[str]] = {k: [] for k in buckets}

    def put(bucket: str, value: float, name: str) -> None:
        buckets[bucket] += value
        if name not in names[bucket]:
            names[bucket].append(name)

    for u in units:
        bucket = "eaten" if u.status == "used" else "wasted" if u.status in WASTED else "in_fridge"
        put(bucket, u.price, u.name)
    from .fridge.shelf_life import lookup
    for line in s.exec(select(CardPurchaseLine).where(CardPurchaseLine.nessie_purchase_id == purchase_id,
                                                      CardPurchaseLine.status != "stocked")):
        put("not_added", line.total, lookup(line.sku).display_name)
    out = {k: round(v, 2) for k, v in buckets.items()}
    out["other"] = round(max(0.0, amount - sum(out.values())), 2)
    out["names"] = names
    return out


def recent_trips(ctx: Ctx, s: Session, household_id: int, limit: int = 3, days: int = 14) -> list[dict]:
    since = ctx.clock.today() - timedelta(days=days)
    rows = s.exec(select(ProcessedPurchase).where(ProcessedPurchase.household_id == household_id,
                                                  ProcessedPurchase.is_grocery == True,  # noqa: E712
                                                  ProcessedPurchase.purchase_date >= since)
                  .order_by(ProcessedPurchase.purchase_date.desc(), ProcessedPurchase.processed_at.desc())
                  .limit(limit))
    return [{"merchant": r.merchant_name, "date": r.purchase_date, "amount": r.amount,
             **purchase_breakdown(s, household_id, r.nessie_purchase_id, r.amount)} for r in rows]


# ---------- budget streak ----------

@dataclass
class Streak:
    weeks: int            # completed weeks in a row at or under budget, newest first
    saved: float          # total moved to the Grocery Fund by budget sweeps
    week_left: float      # budget left this week (negative = over)
    waste_trend: float    # this week's waste minus last week's (negative = wasting less)


def budget_streak(ctx: Ctx, s: Session, hh: Household) -> Streak:
    from .fridge import inventory
    ws = ctx.clock.week_start()
    first = s.exec(select(func.min(ProcessedPurchase.purchase_date))
                   .where(ProcessedPurchase.household_id == hh.id,
                          ProcessedPurchase.is_grocery == True)).first()  # noqa: E712
    weeks = 0
    if first is not None:
        start = ws - timedelta(days=7)
        while start + timedelta(days=7) > first and weeks < 52:
            if grocery_spend(s, hh.id, start, start + timedelta(days=7)) > hh.weekly_budget:
                break
            weeks += 1
            start -= timedelta(days=7)
    saved = 0.0
    import json
    for a in s.exec(select(PendingAction).where(PendingAction.household_id == hh.id,
                                                PendingAction.kind == "transfer", PendingAction.status == "done")):
        saved += float(json.loads(a.payload_json or "{}").get("amount", 0))
    w_start, w_end = inventory.week_bounds(ctx.clock)
    this_waste = sum(w.amount for w in inventory.waste_between(s, hh.id, w_start, w_end))
    last_waste = sum(w.amount for w in inventory.waste_between(s, hh.id, w_start - timedelta(days=7), w_start))
    return Streak(weeks=weeks, saved=round(saved, 2),
                  week_left=round(hh.weekly_budget - grocery_spend(s, hh.id, ws, ws + timedelta(days=7)), 2),
                  waste_trend=round(this_waste - last_waste, 2))


# ---------- shopping list estimate ----------

def fridge_mates(s: Session, household_id: int) -> list[int]:
    """This bank household plus its roommates (bank households sharing the same app fridge)."""
    app_hh = app_household_of(s, household_id)
    if not app_hh:
        return [household_id]
    return sorted({household_id, *(l.household_id for l in s.exec(
        select(SpacetimeLink).where(SpacetimeLink.app_household_id == app_hh)))})


def last_paid(s: Session, household_id: int, sku: str | None, name: str) -> float | None:
    """What the household (or a roommate) last paid per unit, by product (or by name for things added by hand)."""
    q = select(Item).where(Item.household_id.in_(fridge_mates(s, household_id)), Item.price > 0)
    q = q.where(Item.sku == sku) if sku else q.where(func.lower(Item.name) == name.lower())
    row = s.exec(q.order_by(Item.purchased_at.desc())).first()
    return round(row.price, 2) if row else None


def list_estimate(s: Session, household_id: int, rows: list[ShoppingListItem]) -> tuple[float, int]:
    """(estimated total, how many entries had a known price)."""
    total, known = 0.0, 0
    for r in rows:
        p = last_paid(s, household_id, r.sku, r.name)
        if p is not None:
            total += p
            known += 1
    return round(total, 2), known


# ---------- roommates & settle-up ----------

def norm_identity(identity: str | None) -> str:
    return (identity or "").lower().removeprefix("0x")


@dataclass
class Roommate:
    household_id: int
    name: str
    identity: str
    checking_account_id: str | None


@dataclass
class Debt:
    from_id: int
    to_id: int
    amount: float
    items: list[str] = field(default_factory=list)


@dataclass
class SettleState:
    app_household_id: str
    roommates: dict[int, Roommate]
    debts: list[Debt]
    app_uses_available: bool = True

    def name(self, household_id: int) -> str:
        r = self.roommates.get(household_id)
        return r.name if r else "a roommate"

    def owed_by(self, household_id: int) -> list[Debt]:
        return [d for d in self.debts if d.from_id == household_id]

    def owed_to(self, household_id: int) -> list[Debt]:
        return [d for d in self.debts if d.to_id == household_id]


def first_name(s: Session, hh: Household) -> str:
    m = s.exec(select(Member).where(Member.household_id == hh.id).order_by(Member.id)).first()
    if m and m.display_name:
        return m.display_name
    return hh.name.split("'s ")[0] if "'s " in hh.name else hh.name


def app_household_of(s: Session, household_id: int) -> str | None:
    link = s.get(SpacetimeLink, household_id)
    return (link.app_household_id or None) if link else None


def roommates(s: Session, app_household_id: str) -> dict[int, Roommate]:
    out = {}
    for link in s.exec(select(SpacetimeLink).where(SpacetimeLink.app_household_id == app_household_id)):
        hh = s.get(Household, link.household_id)
        if hh:
            out[hh.id] = Roommate(hh.id, first_name(s, hh), norm_identity(link.identity), hh.checking_account_id)
    return out


async def settle_state(ctx: Ctx, app_household_id: str) -> SettleState:
    with Session(ctx.engine) as s:
        rms = roommates(s, app_household_id)
        tokens = [link.token for link in s.exec(select(SpacetimeLink).where(
            SpacetimeLink.app_household_id == app_household_id))]
    app_uses: list[dict] = []
    available = True
    if ctx.spacetime is not None and tokens:
        try:
            app_uses = await ctx.spacetime.query(tokens[0], "SELECT * FROM my_item_uses")
        except Exception as e:  # module without the use log yet: iMessage uses still count
            available = False
            log.info("SpacetimeDB use log unavailable: %s", str(e)[:120])

    with Session(ctx.engine) as s:
        ids = list(rms)
        bank_identities = {r.identity for r in rms.values()}
        people = {r.identity: r.household_id for r in rms.values()}
        for m in s.exec(select(AppMember).where(AppMember.household_id.in_(ids))):
            people[norm_identity(m.identity)] = m.household_id

        # Who paid for each app item, and the unit price, from the payer's own card purchase.
        payer: dict[str, tuple[int, float, str]] = {}
        unit_ext: dict[int, str] = {}
        for link in s.exec(select(SpaceItemLink).where(SpaceItemLink.household_id.in_(ids))):
            unit_ext[link.item_id] = link.external_id
            unit = s.get(Item, link.item_id)
            if unit and unit.source_purchase_id and unit.price > 0:
                payer[link.external_id] = (unit.household_id, unit.price, unit.name)

        owes: dict[tuple[int, int], float] = defaultdict(float)
        names: dict[tuple[int, int], list[str]] = defaultdict(list)

        def charge(consumer: int | None, ext: str | None, qty: int) -> None:
            if consumer is None or ext not in payer:
                return
            paid_by, price, name = payer[ext]
            if paid_by == consumer:
                return
            owes[(consumer, paid_by)] += qty * price
            if name not in names[(consumer, paid_by)]:
                names[(consumer, paid_by)].append(name)

        # USED over iMessage: the household that texted used its own copy of the unit.
        for u in s.exec(select(UsageLog).where(UsageLog.household_id.in_(ids))):
            charge(u.household_id, unit_ext.get(u.item_id), 1)
        # −1 in the app (SpacetimeDB). Rows written by the backend's own identities mirror UsageLog.
        for row in app_uses:
            who = norm_identity(row.get("used_by_hex"))
            if who in bank_identities:
                continue
            charge(people.get(who), row.get("item_id"), int(row.get("qty") or 0))

        paid: dict[tuple[int, int], float] = defaultdict(float)
        for st in s.exec(select(Settlement).where(Settlement.app_household_id == app_household_id)):
            paid[(st.from_household_id, st.to_household_id)] += st.amount

    debts = []
    for a in ids:
        for b in ids:
            if a >= b:
                continue
            net = owes[(a, b)] - owes[(b, a)] - paid[(a, b)] + paid[(b, a)]
            if net > 0.005:
                debts.append(Debt(a, b, round(net, 2), names[(a, b)]))
            elif net < -0.005:
                debts.append(Debt(b, a, round(-net, 2), names[(b, a)]))
    debts.sort(key=lambda d: -d.amount)
    return SettleState(app_household_id, rms, debts, available)


def settle_text(state: SettleState, household_id: int) -> str:
    """The SETTLE reply for one roommate household."""
    def items(d: Debt) -> str:
        return f" ({', '.join(d.items[:3])})" if d.items else ""

    owe, owed = state.owed_by(household_id), state.owed_to(household_id)
    if len(state.roommates) < 2:
        return ("🧾 Settle-up splits groceries between roommates who share this fridge. Each roommate "
                "connects their own bank in the app (Connect your bank) with the household's invite code.")
    if not owe and not owed:
        return "🧾 You're all square with your roommates. 🎉"
    lines = ["🧾 Grocery split"]
    lines += [f"• You owe {state.name(d.to_id)} ${d.amount:,.2f} for what you used{items(d)}" for d in owe]
    lines += [f"• {state.name(d.from_id)} owes you ${d.amount:,.2f}{items(d)}" for d in owed]
    return "\n".join(lines)


def offer_text(state: SettleState, debt: Debt) -> str | None:
    dollars = whole_dollars(debt.amount)
    if dollars < 1:
        return None
    note = "" if abs(dollars - debt.amount) < 0.005 else " (the bank moves whole dollars)"
    return (f"Send {state.name(debt.to_id)} ${dollars} from Everyday Checking{note}? Reply YES or NO.")


_settle_lock = asyncio.Lock()  # one settle computation at a time per process; TransferClaim covers the rest


async def pay(ctx: Ctx, app_household_id: str, from_id: int, to_id: int,
              action_id: int | None = None, quoted: int | None = None,
              claim_key: str | None = None) -> tuple[bool, str]:
    """Moves `quoted` whole dollars (what the person saw and approved) from `from_id` to `to_id`.

    Runs only after a YES (`action_id`, claimed atomically, `quoted` = the offered amount) or a
    confirmed tap in the app (`quoted` = the amount on the dialog). If the debt has dropped below
    what was approved, nothing moves and the person is asked again. A `TransferClaim` keyed on the
    pair and the settlements so far makes a double tap, a second worker or a retry pay once."""
    from . import transfers
    from .brain import pending
    from .photon.outbound import notify_household

    def close(status: str) -> None:
        if action_id is not None:
            pending.finish(ctx.engine, action_id, status)

    async with _settle_lock:
        state = await settle_state(ctx, app_household_id)
        debt = next((d for d in state.debts if d.from_id == from_id and d.to_id == to_id), None)
        current = whole_dollars(debt.amount) if debt else 0
        if action_id is not None and not pending.claim_open(ctx.engine, action_id, ctx.clock.now()):
            return False, "⌛ That offer expired, so nothing moved. Reply SETTLE to see where you stand."
        if current < 1:
            close("done")
            return False, "Nothing to send: you're square (or it's under $1)."
        amount = current if quoted is None else int(quoted)
        if amount > current:
            close("superseded")
            return False, (f"The split changed to ${current} since you confirmed, so nothing moved. "
                           "Check the new amount and confirm again.")
        payer, payee = state.roommates.get(from_id), state.roommates.get(to_id)
        if not payer or not payee or not payer.checking_account_id or not payee.checking_account_id:
            close("failed")
            return False, "One of you has no checking account connected."
        with Session(ctx.engine) as s:
            n_paid = len(list(s.exec(select(Settlement).where(
                Settlement.app_household_id == app_household_id, Settlement.from_household_id == from_id,
                Settlement.to_household_id == to_id))))
        key = f"settle:{app_household_id}:{from_id}:{to_id}:{n_paid}:{amount}"
        if claim_key:
            key += f":{claim_key[:64]}"
        out = await transfers.move(ctx, key, payer.checking_account_id, payee.checking_account_id, amount,
                                   f"DigiFridgy grocery split {payer.name} → {payee.name}",
                                   ctx.clock.today().isoformat())
        if out.status == "duplicate":
            close("done")
            return False, "That payment is already on its way, so nothing extra moved."
        if out.status == "unknown":
            close("failed")
            return False, ("⚠️ The bank didn't confirm that transfer. Check your balance before trying again; "
                           "it won't be sent twice.")
        if not out.money_left:
            close("failed")
            return False, "⚠️ The bank didn't accept that transfer, so nothing moved. Try again later."
        with Session(ctx.engine) as s:
            s.add(Settlement(app_household_id=app_household_id, from_household_id=from_id, to_household_id=to_id,
                             amount=float(amount), nessie_transfer_id=out.transfer_id, settled_at=ctx.clock.now()))
            s.commit()
        close("done")
    items = f" for {', '.join(debt.items[:3])}" if debt.items else ""
    await notify_household(ctx, to_id, f"💸 {payer.name} sent you ${amount} for groceries{items}.",
                           f"settle:{out.transfer_id}")
    note = "" if out.status == "done" else " (the deposit on their side is still going through)"
    return True, f"✅ Sent {payee.name} ${amount} from Everyday Checking{note}. You're square for now."


async def offer(ctx: Ctx, hh: Household, member_id: int | None = None) -> str:
    """The SETTLE reply, plus a YES offer when this household owes someone. With `member_id` (they
    texted SETTLE), only that person's YES can confirm it."""
    from .brain import pending
    with Session(ctx.engine) as s:
        app_hh = app_household_of(s, hh.id)
    if not app_hh:
        return ("🧾 Settle-up needs the shared fridge in the app. Reply APP for the invite code, then "
                "each roommate connects their bank in the app.")
    state = await settle_state(ctx, app_hh)
    text = settle_text(state, hh.id)
    owe = state.owed_by(hh.id)
    if owe:
        ask = offer_text(state, owe[0])
        if ask:
            with Session(ctx.engine) as s:
                pending.create(s, hh.id, "settle", {"app_household_id": app_hh, "to": owe[0].to_id,
                                                    "amount": whole_dollars(owe[0].amount),
                                                    "member_id": member_id}, ctx.clock.now())
                s.commit()
            text += "\n" + ask
    return text


async def request_payment(ctx: Ctx, app_household_id: str, debtor_id: int, creditor_id: int) -> str:
    """The creditor asked (from the app): texts the debtor their split with a YES offer."""
    from .photon.outbound import notify_household
    with Session(ctx.engine) as s:
        debtor = s.get(Household, debtor_id)
        state = await settle_state(ctx, app_household_id)
    if debtor is None or not any(d.from_id == debtor_id and d.to_id == creditor_id for d in state.debts):
        return "They don't owe you anything right now."
    text = await offer(ctx, debtor)
    await notify_household(ctx, debtor_id, f"👋 {state.name(creditor_id)} asked to settle up.\n{text}",
                           f"settle-ask:{debtor_id}:{ctx.clock.real_now().timestamp():.0f}")
    return f"Asked {state.name(debtor_id)} over iMessage."


def trip_line(t: dict) -> str:
    parts = [f"${t['eaten']:,.2f} eaten"] if t["eaten"] >= 0.01 else []
    if t["wasted"]:
        parts.append(f"${t['wasted']:,.2f} wasted")
    if t["in_fridge"]:
        parts.append(f"${t['in_fridge']:,.2f} still in the fridge")
    if t["not_added"]:
        parts.append(f"${t['not_added']:,.2f} not added")
    if t["other"] >= 0.01:
        parts.append(f"${t['other']:,.2f} tax/other")
    parts = parts or ["nothing used yet"]
    when = t["date"].strftime("%a %-m/%-d") if isinstance(t["date"], date) else str(t["date"])
    return f"{when} · ${t['amount']:,.2f} at {t['merchant']}: " + ", ".join(parts)
