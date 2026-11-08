import pytest

from app.brain.router import Intent, keyword_intent, route

from .conftest import run

CASES = [
    ("START", "start", None), ("hi", "start", None), ("FRIDGE", "fridge", None),
    ("what's in my fridge?", "fridge", None), ("EXPIRING", "expiring", None),
    ("What's expiring?", "expiring", None), ("USED milk", "used", "milk"),
    ("I finished the milk", "used", "milk"), ("we ran out of eggs", "used", "eggs"),
    ("TOSSED spinach", "tossed", "spinach"), ("I threw out the strawberries", "tossed", "strawberries"),
    ("LIST", "list", None), ("ADD coffee", "add", "coffee"), ("add coffee to my list", "add", "coffee"),
    ("REMOVE coffee", "remove", "coffee"), ("ADD ALL", "add_all", None), ("MONEY", "money", None),
    ("BUDGET 90", "budget", None), ("YES", "yes", None), ("no", "no", None), ("2", "choice", None),
    ("DINNER", "dinner", None), ("what should I make tonight?", "dinner", None), ("HELP", "help", None),
    ("STOP", "stop", None), ("PRIVACY", "privacy", None), ("do I need eggs?", "check", "eggs"),
    ("got any eggs", "check", "eggs"),
]


@pytest.mark.parametrize("text,intent,item", CASES)
def test_keyword_commands(text, intent, item):
    got = keyword_intent(text)
    assert got is not None and got.name == intent
    if item:
        assert got.item == item


def test_budget_amount():
    assert keyword_intent("budget $92.50").amount == 92.5


class FailingLLM:
    async def classify(self, text):
        raise RuntimeError("boom")


class BadLLM:
    def __init__(self, intent):
        self.intent = intent

    async def classify(self, text):
        return self.intent


def test_llm_failure_falls_back():
    assert run(route("could you peek at my groceries", FailingLLM())).name == "unknown"
    assert run(route("FRIDGE", FailingLLM())).name == "fridge"  # keywords never need the LLM


def test_llm_used_only_for_unmatched_text():
    got = run(route("anything I should cook before it spoils", BadLLM(Intent(name="dinner"))))
    assert got.name == "dinner" and got.source == "llm"


@pytest.mark.parametrize("forbidden", ["yes", "stop", "add_all", "choice", "start", "made_up"])
def test_llm_cannot_confirm_or_invent_intents(forbidden):
    got = run(route("sure go ahead and do the money thing", BadLLM(Intent(name=forbidden))))
    assert got.name == "unknown"
