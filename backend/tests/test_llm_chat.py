"""Messages no command matches go to Gemini for a conversational, read-only reply."""
import json

from sqlmodel import Session, select

from app.brain import copy
from app.brain.llm import GeminiLLM, clean_chat_reply
from app.models import Item, ShoppingListItem

from .conftest import run, text
from .test_photon_features import SAM, group_say
from .test_recipes_and_group import cook, stock  # noqa: F401  (fixture)


class FakeChat:
    def __init__(self, out=None, raises=False):
        self.out = out
        self.raises = raises
        self.calls = []

    async def classify(self, text):
        return None

    async def chat(self, text, facts, in_group=False):
        self.calls.append((text, facts, in_group))
        if self.raises:
            raise RuntimeError("boom")
        return self.out


def test_unknown_message_gets_a_gemini_reply_with_fridge_facts(cook):
    cook.llm = FakeChat({"for_me": True, "reply": "Spinach is best in a day or two. Try RECIPES WITH spinach."})
    reply = text(cook, "is wilted spinach still ok to eat?")
    assert reply.startswith("Spinach is best")
    msg, facts, in_group = cook.llm.calls[0]
    assert msg == "is wilted spinach still ok to eat?" and in_group is False
    names = {f["name"]: f for f in facts["fridge"]}
    spinach = next(v for k, v in names.items() if "pinach" in k)
    assert spinach["use_soon"] is True and spinach["days_left"] == 1
    assert "shopping_list" in facts


def test_commands_never_reach_the_chat(cook):
    cook.llm = FakeChat({"for_me": True, "reply": "nope"})
    text(cook, "fridge")
    text(cook, "add milk")
    assert cook.llm.calls == []


def test_chat_cannot_change_state(cook):
    with Session(cook.engine) as s:
        before = (len(s.exec(select(Item)).all()), len(s.exec(select(ShoppingListItem)).all()))
    cook.llm = FakeChat({"for_me": True, "reply": "Sure thing"})
    text(cook, "can you sort my fridge out for me pls, put milk on there too")
    with Session(cook.engine) as s:
        after = (len(s.exec(select(Item)).all()), len(s.exec(select(ShoppingListItem)).all()))
    assert before == after


def test_chat_failures_fall_back_to_the_canned_reply(cook):
    for fake in (FakeChat(None), FakeChat(raises=True), FakeChat({"for_me": True, "reply": None})):
        cook.llm = fake
        assert text(cook, "blorp the zibble") == copy.UNKNOWN


def test_llm_without_chat_still_works(cook):
    class OldLLM:
        async def classify(self, text):
            return None
    cook.llm = OldLLM()
    assert text(cook, "blorp the zibble") == copy.UNKNOWN


def test_group_chat_stays_quiet_when_people_talk_to_each_other(cook):
    from .conftest import HANDLE
    text(cook, "hi", handle=SAM)
    group_say(cook, HANDLE, "hi")
    cook.llm = FakeChat({"for_me": False, "reply": ""})
    assert group_say(cook, SAM, "omw home, love you") == ""
    assert cook.llm.calls[-1][2] is True
    cook.llm = FakeChat({"for_me": True, "reply": "Eggs keep 3 to 5 weeks in the fridge."})
    assert group_say(cook, SAM, "how long do eggs last?") == "Eggs keep 3 to 5 weeks in the fridge."


def test_clean_chat_reply_strips_markdown_and_action_claims():
    assert clean_chat_reply("**Tip:** keep `milk` cold") == "Tip: keep milk cold"
    assert clean_chat_reply("I've added milk to your list!") is None
    assert clean_chat_reply("I sent $20 to Sam") is None
    assert clean_chat_reply("   ") is None
    assert clean_chat_reply(None) is None
    assert len(clean_chat_reply("word " * 200)) <= 480


def test_gemini_chat_parses_and_forces_for_me_in_one_to_one():
    llm = GeminiLLM("k", "m")

    async def fake_generate(system, user, schema, max_tokens=300):
        payload = json.loads(user)
        assert payload["message"] == "hello?" and "fridge" in payload["facts"]
        return json.dumps({"for_me": False, "reply": "Hey! Text HELP to see what I can do."})

    llm._generate = fake_generate
    got = run(llm.chat("hello?", {"fridge": []}, in_group=False))
    assert got == {"for_me": True, "reply": "Hey! Text HELP to see what I can do."}
    got = run(llm.chat("hello?", {"fridge": []}, in_group=True))
    assert got["for_me"] is False

    async def broken(*a, **k):
        return "not json"
    llm._generate = broken
    assert run(llm.chat("hello?", {"fridge": []})) is None
    run(llm.close())


def test_gemini_falls_back_when_the_main_model_is_unavailable():
    import httpx
    seen = []

    def handler(request):
        model = request.url.path.split("/models/")[1].split(":")[0]
        body = json.loads(request.content)
        seen.append((model, body["generationConfig"].get("thinkingConfig")))
        if model == "gemini-3.5-flash":
            return httpx.Response(503, json={"error": {"message": "high demand"}})
        return httpx.Response(200, json={"candidates": [{"content": {"parts": [
            {"text": "thinking...", "thought": True}, {"text": '{"for_me": true, "reply": "Hi!"}'}]}}]})

    llm = GeminiLLM("k", "gemini-3.5-flash", ("gemini-3.5-flash-lite", "gemini-2.0-flash"))
    llm._http = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    assert run(llm.chat("hello?", {"fridge": []})) == {"for_me": True, "reply": "Hi!"}
    assert [m for m, _ in seen] == ["gemini-3.5-flash", "gemini-3.5-flash-lite"]
    assert all(t == {"thinkingLevel": "low"} for _, t in seen)

    seen.clear()  # the busy model rests for a minute: the next call goes straight to the fallback
    run(llm.chat("hello again", {"fridge": []}))
    assert [m for m, _ in seen] == ["gemini-3.5-flash-lite"]

    seen.clear()
    llm = GeminiLLM("k", "gemini-2.0-flash")
    llm._http = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    run(llm.chat("hello?", {"fridge": []}))
    assert seen == [("gemini-2.0-flash", None)]  # older models don't take thinkingLevel
