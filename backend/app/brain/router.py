"""Text -> intent. Keyword and pattern rules always run first and work with no
LLM. The LLM (optional) only sees what the rules didn't recognize, and it can
never produce YES/NO/STOP/ADD ALL or a numbered choice: those must be typed."""
from __future__ import annotations

import re
from dataclasses import dataclass

INTENTS = ("start", "fridge", "expiring", "used", "tossed", "list", "add", "remove", "add_all", "money",
           "budget", "yes", "no", "choice", "dinner", "help", "stop", "privacy", "check", "app", "link", "settle",
           "trips", "unknown")

# Intents an LLM may return. Confirmations and opt-out are keyword-only.
LLM_INTENTS = ("fridge", "expiring", "used", "tossed", "list", "add", "remove", "money", "budget",
               "dinner", "help", "privacy", "check", "settle", "trips", "unknown")


@dataclass
class Intent:
    name: str
    item: str | None = None
    amount: float | None = None
    choice: int | None = None
    source: str = "keyword"


def _norm(text: str) -> str:
    t = text.strip().lower()
    t = t.replace("’", "'").replace("‘", "'")
    t = re.sub(r"[.!?]+$", "", t).strip()
    return re.sub(r"\s+", " ", t)


_ITEM = r"(?:the |my |our |some |all (?:the |of the )?)?(?P<item>.+?)"
_LIST_SUFFIX = r"(?: (?:to|on|onto|from|off) (?:my |the |our )?(?:shopping |grocery )?list)?"

RULES: list[tuple[str, re.Pattern]] = [(name, re.compile(p)) for name, p in [
    ("stop", r"^(stop|unsubscribe|stop all|quit|end)$"),
    ("start", r"^(start|hi|hello|hey|hiya|yo|sup|ping)( there)?( fridge| digifridgey)?$"),
    ("help", r"^(help|commands|menu|\?|what can you do)$"),
    ("privacy", r"^privacy( policy)?$"),
    ("app", r"^(app|the app|invite|invite code|app code|code|share( (the|my) fridge)?)$"),
    ("link", r"^(?:link|join|connect)(?: (?:to|with))?(?: (?:the )?app)?(?: code)? (?P<item>[a-z0-9]{6})$"),
    ("yes", r"^(yes|y|yep|yeah|yup|ya|sure|ok|okay|confirm|do it)$"),
    ("no", r"^(no|n|nope|nah|cancel|don't|dont|not now)$"),
    ("choice", r"^(?P<choice>[1-9])$"),
    ("add_all", r"^add (them )?all$"),
    ("fridge", r"^(fridge|inventory|show (me )?(my |the )?fridge|what'?s in (my |the )?fridge|what do i have)$"),
    ("expiring", r"^(expiring|use soon|what'?s expiring( soon)?|what is expiring( soon)?|anything expiring( soon)?"
                 r"|what'?s (going|about to go) bad|what expires( soon)?)$"),
    ("list", r"^(list|shopping list|grocery list|my list|show (me )?(my )?list|what'?s on (my |the )?list)$"),
    ("settle", r"^(settle|settle up|split|splits|split (the )?groceries|iou|ious|who owes( who| me| what)?( money)?"
               r"|what do i owe|do i owe (anyone|anybody|someone)( anything)?|roommates?|pay (my )?roommates?)$"),
    ("trips", r"^(trips?|receipts?|purchases|last trip|where did (my|the|our) (grocery )?money go"
              r"|what happened to (my|the|our) groceries)$"),
    ("money", r"^(money|spend|spending|insights?|budget|waste|wasted|how much (did i|have i) (spend|spent|waste|wasted).*)$"),
    ("budget", r"^(set )?(my )?(weekly )?budget (to )?\$?(?P<amount>\d+(?:\.\d{1,2})?)$"),
    ("dinner", r"^(dinner|recipes?|ideas|meal ideas|what should i (make|cook|eat)( tonight| for dinner)?"
               r"|what can i (make|cook)( tonight)?)$"),
    ("used", r"^(used|finished|done|ate it|used it)$"),
    ("tossed", r"^(tossed|toss|threw it out|trashed|binned|tossed it)$"),
    ("used", rf"^(?:i |we )?(?:used( up)?|finished( off)?|ate|drank|done with|polished off|we finished|we used|"
             rf"we ate|out of|ran out of|no more|all out of) {_ITEM}$"),
    ("tossed", rf"^(?:i |we )?(?:tossed|toss|threw out|threw away|trashed|binned|dumped|throw out|"
               rf"had to toss|had to throw out) {_ITEM}(?: out| away)?$"),
    ("add", rf"^(?:please )?(?:add|put|buy|get|need to buy|remind me to buy) {_ITEM}{_LIST_SUFFIX}$"),
    ("remove", rf"^(?:remove|delete|cross off|take off) {_ITEM}{_LIST_SUFFIX}$"),
    ("check", rf"^(?:do i (?:have|need)|do we (?:have|need)|is there|are there|any|got any|how much|how many)"
              rf" (?:any )?{_ITEM}(?: left| in (?:the |my )?fridge)?$"),
]]


def keyword_intent(text: str) -> Intent | None:
    t = _norm(text)
    if not t:
        return None
    for name, rx in RULES:
        m = rx.match(t)
        if not m:
            continue
        g = m.groupdict()
        item = (g.get("item") or "").strip() or None
        if item:
            item = re.sub(r"\b(please|pls|thanks|thank you)\b", "", item).strip(" ,") or None
        amount = float(g["amount"]) if g.get("amount") else None
        choice = int(g["choice"]) if g.get("choice") else None
        return Intent(name=name, item=item, amount=amount, choice=choice)
    return None


async def route(text: str, llm=None) -> Intent:
    hit = keyword_intent(text)
    if hit:
        return hit
    if llm is not None:
        try:
            got = await llm.classify(text)
        except Exception:
            got = None
        if got and got.name in LLM_INTENTS:
            got.source = "llm"
            return got
    return Intent(name="unknown")
