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


def stock_question(merchant: str, amount: float, count: int, names: list[str]) -> str:
    shown = ", ".join(names[:3]) + (f" +{len(names) - 3} more" if len(names) > 3 else "")
    return (f"🧾 Card purchase at {merchant} ({usd(amount)}): {shown}\n"
            f"Add all {count} items to your fridge? Reply YES or NO, or pick items in the app.")


def stock_declined(left: int) -> str:
    return "👍 Not added. Pick items anytime in the app under + → Add from card." if left else "👍 OK."


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
    lines.append("Reply USE THEM UP for recipes with these")
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


def shopping_list(active, suggested, estimate: tuple[float, int] | None = None,
                  week_left: float | None = None, claims: dict | None = None) -> str:
    if not active and not suggested:
        return "🛒 Your list is empty. Reply ADD <item> to add something."
    out = []
    if active:
        out.append("🛒 Shopping list")
        claims = claims or {}
        out.extend(f"• {r.name}" + (f" ({claims[r.id]}'s got it)" if r.id in claims else "") for r in active)
        if estimate and estimate[1]:
            total, known = estimate
            basis = "" if known == len(active) else f" for the {known} you've bought before"
            line = f"≈ {usd(total)}{basis} at what you last paid"
            if week_left is not None:
                line += (f" · {usd(week_left)} left in this week's budget" if week_left >= 0
                         else f" · already {usd(-week_left)} over this week's budget")
                if 0 <= week_left < total:
                    line += " ⚠️"
            out.append(line)
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


def sweep_offer(under: float, move: float, streak=None) -> str:
    text = f"🏦 You're {usd(under)} under budget this week.\n"
    if streak is not None:
        text += streak_line(streak, including_this_week=True) + "\n"
    return text + f"Move {usd(move)} to Grocery Fund? Reply YES or NO."


def streak_line(streak, including_this_week: bool = False) -> str:
    """'Waste less, save more': weeks in a row under budget and what the sweeps saved."""
    weeks = streak.weeks + (1 if including_this_week else 0)
    parts = []
    if weeks >= 2:
        parts.append(f"🔥 {weeks} weeks in a row under budget")
    elif weeks == 1:
        parts.append("🔥 1 week under budget, keep it going")
    if streak.saved:
        parts.append(f"{usd(streak.saved)} saved to Grocery Fund so far")
    if streak.waste_trend < -0.005:
        parts.append(f"wasting {usd(-streak.waste_trend)} less than last week")
    return " · ".join(parts) if parts else "Stay under budget this week to start a savings streak."


def over_budget(ins) -> str:
    return (f"🏦 This week: {usd(ins.week_spend)} on groceries vs a {usd(ins.budget)} budget.\n"
            "Nothing left to move to Grocery Fund this time.")


def already_swept(amount: float) -> str:
    return (f"🏦 You already moved {usd(amount)} to Grocery Fund this week.\n"
            "Nothing new to move until next week.")


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
            "Still have it? Reply USED, TOSSED, or RECIPES for ideas.")


def nudge_many(items, clock) -> str:
    names = ", ".join(f"{i.name} ({day_label(i.expires_at, clock)})" for i in items)
    return f"⏰ Use soon: {names}\nReply USED <item>, TOSSED <item>, or RECIPES for ideas."


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


def _names(pairs, n: int) -> str:
    """[(name, day label)] -> "spinach (tomorrow), eggs (Nov 20) +2 more"."""
    shown = ", ".join(f"{name} ({day})" for name, day in pairs[:n])
    return shown + (f" +{len(pairs) - n} more" if len(pairs) > n else "")


def recipes_list(rows: list[tuple], focus: str | None = None, have_focus: bool = True,
                 no_recipe_for: str | None = None, what: str | None = None, none_fit: str | None = None) -> str:
    """rows: (recipe name, [(item you have, day label)] soonest first, [missing ingredient], optional
    "15 min · easy"). `what`: "easy recipes" etc. for an easy/quick ask; `none_fit`: none were that easy."""
    if none_fit:
        head = f"🤔 No {none_fit} for what's in your fridge right now. Here's what you can make:"
    elif no_recipe_for:
        head = f"🤔 I don't have a recipe with {no_recipe_for} yet. Here's what your fridge can make:"
    elif focus and not have_focus:
        head = f"🍳 You're out of {focus}, but here's what it goes in:"
    elif focus:
        head = f"🍳 {(what or 'recipes').capitalize()} with the {focus}, soonest-expiring food first:"
    elif what:
        head = f"🍳 {what.capitalize()} you can make, soonest-expiring food first:"
    else:
        head = "🍳 What you can make, soonest-expiring food first:"
    out = [head]
    for n, row in enumerate(rows, 1):
        name, have, missing = row[:3]
        info = row[3] if len(row) > 3 else None
        out.append(f"{n}) {name}" + (f" ({info})" if info else ""))
        parts = []
        if have:
            parts.append("uses " + _names(have, 2))
        if missing:
            parts.append("need " + ", ".join(missing[:2]) + (f" +{len(missing) - 2}" if len(missing) > 2 else ""))
        else:
            parts.append("you have it all")
        out.append("   " + " · ".join(parts))
    count = len(rows)
    out.append("Reply 1 for the ingredients." if count == 1 else f"Reply 1-{count} for the ingredients.")
    return "\n".join(out)


def recipes_expiring(expiring: list[tuple[str, str]], rows: list, none_use_them: bool = False,
                     what: str | None = None, none_fit: str | None = None) -> str:
    """Recipes that use what's about to expire. expiring: (item, day label) soonest first."""
    if not expiring:
        head = "✅ Nothing's about to expire. Here's what you can make:"
    elif none_use_them:
        head = f"🤔 None of my recipes use {_names(expiring, 3)} yet. Here's what your fridge can make:"
    elif none_fit:
        head = f"🤔 No {none_fit} use {_names(expiring, 3)}. These do:"
    else:
        head = f"⏰ {(what or 'recipes').capitalize()} that use what's about to expire ({_names(expiring, 3)}):"
    body = recipes_list(rows).split("\n", 1)[1]  # same numbered rows and "Reply 1-3" as RECIPES
    return head + "\n" + body


def recipe_detail(name: str, have: list[tuple[str, str]], missing: list[str], on_list: list[str],
                  pantry: list[str]) -> str:
    out = [f"🍳 {name}"]
    if have:
        out.append("✅ You have: " + _names(have, 6))
    if missing or on_list:
        out.append("🛒 Missing: " + ", ".join(missing + [f"{n} (on your list)" for n in on_list]))
    if pantry:
        out.append("🧂 Pantry: " + ", ".join(dict.fromkeys(pantry)))
    if missing:
        it = missing[0] if len(missing) == 1 else "the missing ones"
        out.append(f"Add {it} to your shopping list? Reply YES or NO.")
    elif on_list:
        out.append("Everything else is in your fridge.")
    else:
        out.append("You have everything. Enjoy! Reply USED <item> when you cook.")
    return "\n".join(out)


def recipes_empty() -> str:
    return "🧊 Your fridge is empty, so there's nothing to cook yet. Reply LIST to plan a grocery run."


def recipes_none() -> str:
    return ("🤔 Nothing in my recipes fits what's in your fridge right now. "
            "Reply INGREDIENTS to see what you have, or LIST to plan a grocery run.")


def ingredients(soon: list[tuple[str, str]], rest: list[tuple[str, str]]) -> str:
    if not soon and not rest:
        return recipes_empty()
    out = ["🥕 Your ingredients"]
    if soon:
        out.append("⏰ Use first: " + _names(soon, 6))
    if rest:
        names = [n for n, _ in rest]
        out.append(("Also: " if soon else "You have: ") + ", ".join(names[:12])
                   + (f" +{len(names) - 12} more" if len(names) > 12 else ""))
    first = (soon or rest)[0][0]
    out.append(f"Reply RECIPES for ideas, or RECIPES WITH {first}.")
    return "\n".join(out)


# ---------- family group chat ----------

def pretty_handle(handle: str) -> str:
    """+14695550123 -> (469) 555-0123; other numbers and emails as they are."""
    if handle.startswith("+1") and len(handle) == 12 and handle[1:].isdigit():
        return f"({handle[2:5]}) {handle[5:8]}-{handle[8:]}"
    return handle


def join_names(names: list[str]) -> str:
    names = [n for n in names if n]
    if len(names) <= 1:
        return "".join(names)
    return ", ".join(names[:-1]) + " and " + names[-1]


def group_welcome(name: str, people: list[str] | None = None, strangers: list[str] | None = None) -> str:
    """First message in a new household group. `people`: household members in it, by name;
    `strangers`: numbers in it that aren't in the household yet."""
    hi = f"👋 Hi {join_names(people)}!" if people else "👋 Hi all!"
    text = (f"{hi} This group is now {name}'s fridge chat. Ask \"who's grabbing milk?\" and "
            "reply I WILL to take it, ask WHAT CAN I MAKE?, send a photo of a receipt, or ask what's expiring. "
            "Money questions stay in your own chats with me.")
    if strangers:
        nums = ", ".join(pretty_handle(h) for h in strangers[:4])
        text += f"\nI don't know {nums} yet. Anyone in the household can text INVITE <their number> to add them."
    return text


def group_instructions(hh_name: str, others: list[tuple[str, str]], agent: str | None) -> str:
    """How to start the household group on a line that can't start chats. others: (name, handle)."""
    me = f"me at {pretty_handle(agent)}" if agent else "me (this number)"
    if others:
        who = ", ".join(f"{n} {pretty_handle(h)}" if n else pretty_handle(h) for n, h in others[:6])
        step1 = f"1) In Messages, start a new group with {who} and {me}."
    else:
        step1 = f"1) In Messages, start a new group with your family or roommates and {me}."
    lines = ["👪 Get the household in one chat:", step1,
             "2) Send anything in it, like \"hi fridge\".",
             f"I'll link it to {hh_name} and say hi to everyone by name."]
    lines.append("Adding someone new? Text INVITE <their number> first, like INVITE Mom (469) 555-0123."
                 if others else "Text INVITE <number> first so I know who's in the household.")
    return "\n".join(lines)


def group_unavailable(others: list[tuple[str | None, str]], agent: str | None) -> str:
    """GROUP on a shared line. Photon's shared lines never receive messages sent in a group chat, so a
    group with the agent in it would get no answers: everyone texts the agent 1:1 instead."""
    me = f"me at {pretty_handle(agent)}" if agent else "this number"
    lines = ["👪 I can't answer in group chats on this line, so a group with me in it won't get replies.",
             f"Instead, everyone texts {me} directly. You all share the same fridge and shopping list."]
    if others:
        lines.append(f"Sharing it now: {join_names([n or pretty_handle(h) for n, h in others[:6]])}.")
        lines.append("Adding someone? Text INVITE <their number>, like INVITE Mom (469) 555-0123.")
    else:
        lines.append("Add your family or roommates: text INVITE <their number>, like INVITE Mom (469) 555-0123.")
    return "\n".join(lines)


def group_created(names: list[str]) -> str:
    return f"✅ Started a group chat with {join_names(names)} and me. Say hi there!"


def group_already(hh_name: str, names: list[str]) -> str:
    who = f" Household: {join_names(names)}." if names else ""
    return f"✅ This chat is already {hh_name}'s fridge chat.{who} Text INVITE <number> to add someone."


def invited(name: str | None, handle: str, hh_name: str, agent: str | None, has_group: bool,
            can_group: bool = True) -> str:
    """`can_group`: GROUP can set up a group chat (a dedicated line). On a shared line it can't."""
    who = f"{name} ({pretty_handle(handle)})" if name else pretty_handle(handle)
    reach = f"text me at {pretty_handle(agent)}" if agent else "text this number"
    where = (", or add them to your group chat with me" if has_group
             else ", or text GROUP to get everyone in one chat" if can_group else "")
    return (f"✅ {who} is invited to {hh_name}.\n"
            f"I can't text first, so ask them to {reach}{where}.\n"
            "They'll see the fridge and list. Money still needs your own YES.")


def invited_welcome(name: str | None, hh_name: str, by: str | None) -> str:
    hi = f"👋 Hi {name}!" if name else "👋 Hi!"
    who = f"{by} added you to" if by else "You're in"
    return (f"{hi} I'm DigiFridgy. {who} {hh_name}'s shared fridge.\n"
            "Try: FRIDGE, WHAT CAN I MAKE?, LIST, who's grabbing milk? HELP lists everything. STOP ends messages.")


def stranger_in_group(hh_name: str) -> str:
    return (f"👋 Hi! I'm DigiFridgy, {hh_name}'s fridge assistant. I only answer people in the household, "
            "so I'll stay quiet for you. Anyone in it can text INVITE <your number> to add you.")


def name_set(name: str) -> str:
    return f"👋 Nice to meet you, {name}! That's what I'll call you in your group chat."


GUEST_MONEY = "💳 Only the account holder can move money. They can reply YES in their own chat with me or in the app."


def welcome(name: str, new: bool) -> str:
    if not new:
        return "👋 Welcome back! Reply FRIDGE, EXPIRING, LIST, MONEY, or HELP."
    return ("👋 Hi! I'm DigiFridgy, your fridge, linked to your (demo) bank account.\n"
            f"You're in the {name}. When you buy groceries, I stock your fridge and text you "
            "before food goes bad.\n"
            "Try: FRIDGE, what's expiring?, I finished the milk, MONEY. HELP lists everything. STOP ends messages.")


HELP = ("🧊 DigiFridgy commands\n"
        "FRIDGE · EXPIRING · INGREDIENTS\n"
        "RECIPES · RECIPES WITH <item> (then reply a number)\n"
        "USED <item> · TOSSED <item>\n"
        "LIST · ADD <item> · REMOVE <item> · ADD ALL\n"
        "MONEY · BUDGET <amount> · TRIPS\n"
        "SETTLE (split groceries with roommates)\n"
        "GROUP (family group chat) · INVITE <number>\n"
        "Who's grabbing milk? · I'll get eggs · I WILL\n"
        "Send a photo of a receipt or your fridge\n"
        "YES / NO answers my questions\n"
        "APP (invite code for the iPhone app) · LINK <code>\n"
        "PRIVACY · STOP\n"
        "Or just ask: what can I make with the spinach?")

PRIVACY = ("🔒 DigiFridgy runs on synthetic demo bank data (Capital One's Nessie sandbox), not real accounts. "
           "We store your iMessage handle, this chat's ID, and your fridge items. "
           "Money never moves without your YES. Reply STOP to unlink and stop all messages.")

STOPPED = "You're unsubscribed. I won't text you again. Reply START anytime to come back."

UNKNOWN = "Sorry, I didn't get that. Reply HELP for what I can do."

NOT_TEXT = "I can only read text for now. Reply HELP for options."

APP_OFF = "The iPhone app connection isn't set up on this server."
