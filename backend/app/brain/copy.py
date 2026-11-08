"""Every message the agent sends. iMessage is plain text: short lines, emoji as
markers, no Markdown."""
from __future__ import annotations

from collections import OrderedDict
from datetime import datetime


def usd(x: float | None) -> str:
    return "$?" if x is None else f"${x:,.2f}"


def day_label(dt: datetime, clock) -> str:
    d = clock.to_local(dt).date()
    delta = (d - clock.today()).days
    if delta < 0:
        return "expired"
    if delta == 0:
        return "today"
    if delta == 1:
        return "tomorrow"
    if delta < 7:
        return d.strftime("%a")
    return d.strftime("%b %-d")


def _grouped(items) -> "OrderedDict[str, list]":
    """Groups units of the same SKU; keeps the earliest expiry first."""
    groups: OrderedDict[str, list] = OrderedDict()
    for it in sorted(items, key=lambda i: i.expires_at):
        groups.setdefault(it.sku, []).append(it)
    return groups


def _line(units, clock, with_emoji=True) -> str:
    first = units[0]
    qty = f" x{len(units)}" if len(units) > 1 else ""
    em = f"{first.emoji} " if with_emoji and first.emoji else ""
    return f"{em}{first.name}{qty} ({day_label(first.expires_at, clock)})"


def stocked(merchant: str, amount: float, fresh, clock) -> str:
    groups = _grouped(fresh)
    first = [f"{g[0].name} ({day_label(g[0].expires_at, clock)})" for g in list(groups.values())[:2]]
    lines = [f"🧊 Stocked {len(fresh)} items from {merchant} ({usd(amount)})"]
    if first:
        lines.append("Use first: " + ", ".join(first))
    lines.append("Reply FRIDGE to see everything")
    return "\n".join(lines)


SECTION_MAX = 8


def fridge(items, clock, use_soon_ids: set[int]) -> str:
    if not items:
        return "🧊 Your fridge is empty.\nBuy groceries with your card and I'll stock it automatically."
    soon = [i for i in items if i.id in use_soon_ids]
    rest = [i for i in items if i.id not in use_soon_ids]
    sections = [("⏰ Use soon", soon),
                ("🧊 Fridge", [i for i in rest if i.location == "fridge"]),
                ("❄️ Freezer", [i for i in rest if i.location == "freezer"]),
                ("🧺 Pantry", [i for i in rest if i.location == "pantry"])]
    out = [f"Your fridge ({len(items)} items)"]
    for title, rows in sections:
        if rows:
            groups = list(_grouped(rows).values())
            out.append("")
            out.append(title)
            out.extend(_line(g, clock) for g in groups[:SECTION_MAX])
            if len(groups) > SECTION_MAX:
                out.append(f"…and {len(groups) - SECTION_MAX} more")
    out.append("")
    out.append("Reply USED <item> or TOSSED <item> to update")
    return "\n".join(out)


def expiring(items, clock) -> str:
    if not items:
        return "✅ Nothing expires in the next 2 days."
    lines = ["⏰ Use soon:"] + [_line(g, clock) for g in _grouped(items).values()]
    lines.append("Reply DINNER for ideas")
    return "\n".join(lines)


def marked(name: str, status: str, remaining: int, wasted: float = 0.0, week_waste: float = 0.0) -> str:
    if status == "tossed":
        msg = f"🗑️ Tossed the {name} ({usd(wasted)} of food)."
        if week_waste:
            msg += f"\nWasted this week: {usd(week_waste)}"
        return msg
    msg = f"✅ Marked the {name} as used."
    if remaining:
        msg += f" {remaining} left."
    return msg


def suggestions_prompt(names: list[str]) -> str:
    it = "it" if len(names) == 1 else "them"
    return f"🛒 You're out of {', '.join(names)}.\nReply ADD ALL to put {it} on your list."


def bulk_marked(n: int, category: str, status: str = "used") -> str:
    return f"✅ Marked {n} {category} items as {status}."


def shopping_list(active, suggested) -> str:
    if not active and not suggested:
        return "🛒 Your list is empty. Reply ADD <item> to add something."
    out = []
    if active:
        out.append("🛒 Shopping list")
        out.extend(f"• {r.name}" for r in active)
    if suggested:
        if out:
            out.append("")
        out.append("💡 Suggested (you're out)")
        out.extend(f"• {r.name}" for r in suggested)
        out.append("Reply ADD ALL to add these")
    return "\n".join(out)


def added(names: list[str]) -> str:
    return f"🛒 Added {', '.join(names)} to your list."


def removed(name: str) -> str:
    return f"🛒 Removed {name} from your list."


def not_on_list(q: str) -> str:
    return f"I couldn't find {q} on your list. Reply LIST to see it."


def money(ins) -> str:
    lines = [f"💸 This week: {usd(ins.week_spend)} on groceries (budget {usd(ins.budget)})"]
    if ins.last_week_spend:
        diff = ins.week_spend - ins.last_week_spend
        word = "more" if diff > 0 else "less"
        lines.append(f"Last week: {usd(ins.last_week_spend)} ({usd(abs(diff))} {word} so far)")
    if ins.week_waste:
        names = ", ".join(ins.week_waste_names[:3])
        lines.append(f"Wasted: {usd(ins.week_waste)} ({names})")
    else:
        lines.append("Wasted this week: $0.00 🎉")
    lines.append(f"Month to date: {usd(ins.month_waste)} wasted")
    return "\n".join(lines)


def budget_set(amount: float) -> str:
    return f"✅ Weekly grocery budget set to {usd(amount)}."


def sweep_offer(under: float, move: float) -> str:
    return (f"🏦 You're {usd(under)} under budget this week.\n"
            f"Move {usd(move)} to Grocery Fund? Reply YES or NO.")


def over_budget(ins) -> str:
    return (f"🏦 This week: {usd(ins.week_spend)} on groceries vs a {usd(ins.budget)} budget.\n"
            "Nothing left to move to Grocery Fund this time.")


def transfer_done(amount: float, checking: float | None, fund: float | None) -> str:
    return (f"✅ Moved {usd(amount)} → Grocery Fund\n"
            f"Checking: {usd(checking)} · Grocery Fund: {usd(fund)}")


def transfer_declined() -> str:
    return "👍 No problem, nothing moved."


def offer_expired() -> str:
    return "⌛ That offer expired, so nothing moved. Reply MONEY to see where you stand."


def transfer_failed() -> str:
    return "⚠️ The bank didn't accept that transfer, so nothing moved. Try again later."


def nothing_pending() -> str:
    return "Nothing is waiting on a yes/no right now. Reply HELP for options."


def nudge_one(item, clock) -> str:
    return (f"⏰ Your {item.name} expires {day_label(item.expires_at, clock)}.\n"
            "Still have it? Reply USED, TOSSED, or DINNER for ideas.")


def nudge_many(items, clock) -> str:
    names = ", ".join(f"{i.name} ({day_label(i.expires_at, clock)})" for i in items)
    return f"⏰ Use soon: {names}\nReply USED <item>, TOSSED <item>, or DINNER for ideas."


def still_have_it(name: str) -> str:
    return f"👍 Great, use the {name} soon."


def expired_notice(items, week_waste: float, month_waste: float) -> str:
    total = sum(i.price for i in items)
    names = ", ".join(sorted({i.name for i in items}))
    return (f"🗑️ Expired: {names} ({usd(total)})\n"
            f"💸 Wasted this week: {usd(week_waste)} · month: {usd(month_waste)}")


def disambiguate(query: str, options: list[tuple[str, str]]) -> str:
    lines = [f"Which {query}?"]
    lines += [f"{n}) {name} (bought {bought})" for n, (name, bought) in enumerate(options, 1)]
    lines.append("Reply " + " or ".join(str(n) for n in range(1, len(options) + 1)))
    return "\n".join(lines)


def bulk_confirm(category: str, names: list[str]) -> str:
    return (f"Mark all {len(names)} {category} items as used? ({', '.join(names)})\n"
            "Reply YES or NO.")


def not_in_fridge(q: str) -> str:
    return f"I don't see {q} in your fridge. Reply FRIDGE to check."


def check(q: str, units, clock) -> str:
    if not units:
        return f"🤔 You're out of {q}. Reply ADD {q} to put it on your list."
    first = units[0]
    qty = f"{len(units)} × " if len(units) > 1 else ""
    return f"✅ You have {qty}{first.name}, good until {day_label(first.expires_at, clock)}."


def dinner(ideas: list[str]) -> str:
    return "🍳 Ideas for tonight:\n" + "\n".join(f"• {i}" for i in ideas)


def welcome(name: str, new: bool) -> str:
    if not new:
        return "👋 Welcome back! Reply FRIDGE, EXPIRING, LIST, MONEY, or HELP."
    return ("👋 Hi! I'm DigiFridgey, your fridge, linked to your (demo) bank account.\n"
            f"You're in the {name}. When you buy groceries, I stock your fridge and text you "
            "before food goes bad.\n"
            "Try: FRIDGE, what's expiring?, I finished the milk, MONEY. HELP lists everything. STOP ends messages.")


HELP = ("🧊 DigiFridgey commands\n"
        "FRIDGE · EXPIRING · DINNER\n"
        "USED <item> · TOSSED <item>\n"
        "LIST · ADD <item> · REMOVE <item> · ADD ALL\n"
        "MONEY · BUDGET <amount>\n"
        "YES / NO answers my questions\n"
        "PRIVACY · STOP\n"
        "Or just ask: do I have eggs?")

PRIVACY = ("🔒 DigiFridgey runs on synthetic demo bank data (Capital One's Nessie sandbox), not real accounts. "
           "We store your iMessage handle, this chat's ID, and your fridge items. "
           "Money never moves without your YES. Reply STOP to unlink and stop all messages.")

STOPPED = "You're unsubscribed. I won't text you again. Reply START anytime to come back."

UNKNOWN = "Sorry, I didn't get that. Reply HELP for what I can do."

NOT_TEXT = "I can only read text for now. Reply HELP for options."
