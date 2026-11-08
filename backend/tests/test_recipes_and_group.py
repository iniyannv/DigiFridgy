"""Recipes and ingredients over text, and getting a household into one group chat."""
from datetime import timedelta

import pytest
from fastapi.testclient import TestClient
from sqlmodel import Session, select

from app.brain import pending, recipes
from app.brain.router import LLM_INTENTS, keyword_intent
from app.fridge.shelf_life import lookup
from app.main import create_app
from app.models import HouseholdInvite, HouseholdSpace, Item, Member, PendingAction, ShoppingListItem

from .conftest import BASE, HANDLE, household, run, text
from .test_photon_features import SAM, group_say

MOM = "+14695550123"
JORDAN = "+15555550177"
STRANGER = "+15555550111"


def stock(ctx, days: dict[str, int]) -> None:
    """Puts one unit of each SKU in the fridge, expiring in that many days."""
    hh = household(ctx)
    with Session(ctx.engine) as s:
        for sku, d in days.items():
            info = lookup(sku)
            s.add(Item(household_id=hh.id, sku=sku, name=info.display_name, category=info.category,
                       location=info.location, emoji=info.emoji, price=3.0, purchased_at=BASE - timedelta(days=1),
                       expires_at=BASE + timedelta(days=d), status="fresh"))
        s.commit()


def list_names(ctx) -> list[str]:
    with Session(ctx.engine) as s:
        return [r.name for r in s.exec(select(ShoppingListItem).where(ShoppingListItem.done == False,  # noqa: E712
                                                                      ShoppingListItem.confirmed == True))]  # noqa: E712


@pytest.fixture
def cook(seeded):
    ctx = seeded
    text(ctx, "hi")
    # Spinach goes bad tomorrow; chicken soon; eggs, rice and cheddar keep.
    stock(ctx, {"spinach_5oz": 1, "chicken_breast_2lb": 2, "eggs_dozen": 12, "rice_2lb": 90,
                "cheddar_block_16oz": 20})
    return ctx


# ---------- router ----------

@pytest.mark.parametrize("msg,intent,item", [
    ("what can I make?", "dinner", None),
    ("What can I cook with the spinach?", "dinner", "spinach"),
    ("recipes with chicken", "dinner", "chicken"),
    ("chicken recipes", "dinner", "chicken"),
    ("how do I use up the spinach", "dinner", "spinach"),
    ("what should we make with the eggs tonight", "dinner", "eggs"),
    ("what ingredients do I have?", "ingredients", None),
    ("ingredients", "ingredients", None),
    ("what can I cook with", "ingredients", None),
    ("group", "group", None),
    ("start a group chat", "group", None),
    ("how do I add my family to the group chat?", "group", None),
    ("add milk", "add", "milk"),
    ("add 12 eggs", "add", "12 eggs"),
    ("call me Sam", "name", "sam"),
])
def test_routes(msg, intent, item):
    got = keyword_intent(msg)
    assert got is not None and got.name == intent and got.item == item


def test_number_follow_ups_and_invites_route():
    assert keyword_intent("recipe 2").choice == 2
    assert keyword_intent("ingredients for 3").choice == 3
    got = keyword_intent("invite Mom (469) 555-0123")
    assert got.name == "invite" and got.item == "(469) 555-0123" and got.person == "Mom"
    got = keyword_intent("add my sister +14695550123 to the group")
    assert got.name == "invite" and got.person == "Sister"
    assert keyword_intent("invite").name == "app"  # bare INVITE is still the app code


def test_group_and_invite_are_keyword_only():
    for name in ("group", "invite", "name"):
        assert name not in LLM_INTENTS
    assert "ingredients" in LLM_INTENTS


# ---------- scoring ----------

def test_scoring_matches_the_app(cook):
    ctx = cook
    with Session(ctx.engine) as s:
        fresh = list(s.exec(select(Item).where(Item.status == "fresh").order_by(Item.expires_at)))
    omelet = next(r for r in recipes.TEMPLATES if r["name"] == "Spinach and cheddar omelet")
    sc = recipes.score_recipe(omelet, fresh, ctx.clock)
    # spinach expires within 3 days (+3), eggs and cheddar keep (+1 each), nothing missing.
    assert sc.score == 5 and not sc.missing and [i.sku for _, i in sc.have][0] == "spinach_5oz"
    fried = next(r for r in recipes.TEMPLATES if r["name"] == "Chicken fried rice")
    sc = recipes.score_recipe(fried, fresh, ctx.clock)
    assert sc.score == 3 + 1 + 1 - 1 and [m["sku"] for m in sc.missing] == ["frozen_peas_12oz"]


# ---------- recipes over text ----------

def test_what_can_i_make_starts_with_what_expires_soonest(cook):
    reply = text(cook, "what can I make?")
    lines = reply.splitlines()
    assert lines[0].startswith("🍳 What you can make")
    assert lines[1].startswith("1) ") and "spinach (tomorrow)" in lines[2]
    assert reply.endswith("Reply 1-3 for the ingredients.")
    assert len(reply) < 600


def test_reply_a_number_for_ingredients_then_yes_adds_missing(cook):
    ctx = cook
    reply = text(ctx, "what can I make?")
    names = [ln[3:] for ln in reply.splitlines() if ln[:1].isdigit()]
    detail = text(ctx, "2")
    assert detail.startswith(f"🍳 {names[1]}") and "✅ You have:" in detail
    assert text(ctx, "7") == "Reply a number from 1 to 3."
    fried = text(ctx, "recipes with chicken")
    pick = next(ln.split(") ", 1)[0] for ln in fried.splitlines() if "Chicken fried rice" in ln)
    detail = text(ctx, pick)
    assert "🛒 Missing: frozen peas" in detail and "🧂 Pantry: soy sauce" in detail
    assert "Reply YES or NO" in detail
    assert text(ctx, "yes") == "🛒 Added frozen peas to your list."
    assert "frozen peas" in list_names(ctx)
    # Asking again: it's on the list now, so no second offer.
    again = text(ctx, pick)
    assert "frozen peas (on your list)" in again and "Reply YES" not in again


def test_no_leaves_the_list_alone(cook):
    ctx = cook
    fried = text(ctx, "recipes with chicken")
    pick = next(ln.split(") ", 1)[0] for ln in fried.splitlines() if "Chicken fried rice" in ln)
    text(ctx, pick)
    assert "left your list" in text(ctx, "no")
    assert list_names(ctx) == []


def test_focus_ingredient_only_shows_recipes_with_it(cook):
    reply = text(cook, "what can I cook with the spinach?")
    assert reply.startswith("🍳 Recipes with the spinach")
    names = [ln[3:] for ln in reply.splitlines() if ln[:1].isdigit()]
    with_spinach = {r["name"] for r in recipes.TEMPLATES if "spinach_5oz" in [i["sku"] for i in r["ingredients"]]}
    assert names and set(names) <= with_spinach


def test_focus_you_dont_have_and_focus_with_no_recipe(cook):
    assert "You're out of salmon" in text(cook, "salmon recipes")
    reply = text(cook, "recipes with tofu")
    assert reply.startswith("🤔 I don't have a recipe with tofu yet") and "1) " in reply


def test_empty_fridge(seeded):
    text(seeded, "hi")
    assert "fridge is empty" in text(seeded, "what can I make?")
    assert "fridge is empty" in text(seeded, "ingredients")


def test_ingredients_lists_soonest_first(cook):
    reply = text(cook, "what ingredients do I have?")
    assert reply.splitlines()[1] == "⏰ Use first: spinach (tomorrow), chicken breast (Mon)"
    assert "Also: eggs, cheddar, rice" in reply
    assert reply.endswith("RECIPES WITH spinach.")


def test_number_reply_still_answers_a_newer_which_one_question(cook):
    ctx = cook
    text(ctx, "what can I make?")
    stock(ctx, {"milk_whole_1gal": 5, "milk_2pct_1gal": 6})
    assert text(ctx, "used milk").startswith("Which milk?")
    assert "Marked" in text(ctx, "1")  # the newer question wins


class FakeLLM:
    def __init__(self, out):
        self.out = out
        self.asked = None

    async def classify(self, text):
        return None

    async def recipes(self, use_soon, have, focus=None):
        self.asked = (use_soon, have, focus)
        return self.out


def test_llm_recipes_are_checked_against_the_fridge(cook):
    ctx = cook
    ctx.llm = FakeLLM([{"name": "Spinach egg fried rice", "ingredients": ["spinach", "eggs", "rice", "scallions"]}])
    reply = text(ctx, "what can I make with the spinach")
    assert "1) Spinach egg fried rice" in reply and "need scallions" in reply
    assert ctx.llm.asked[2] == "spinach" and "spinach" in ctx.llm.asked[0]
    detail = text(ctx, "1")
    assert "🛒 Missing: scallions" in detail
    assert text(ctx, "yes") == "🛒 Added scallions to your list."


def test_llm_failure_falls_back_to_templates(cook):
    cook.llm = FakeLLM(None)
    assert "1) " in text(cook, "what can I make?")


def test_recipes_in_the_group_chat(cook):
    ctx = cook
    text(ctx, "hi", handle=SAM)
    group_say(ctx, HANDLE, "hi")
    reply = group_say(ctx, SAM, "what can we make with the chicken?")
    pick = next(ln.split(") ", 1)[0] for ln in reply.splitlines() if "Chicken fried rice" in ln)
    assert "Reply YES" in group_say(ctx, HANDLE, pick)
    assert "Added frozen peas" in group_say(ctx, SAM, "yes")  # a list change, not money: fine in the group


def test_approval_card_describes_missing_ingredients(cook):
    from app.brain.approvals import describe
    ctx = cook
    fried = text(ctx, "recipes with chicken")
    text(ctx, next(ln.split(") ", 1)[0] for ln in fried.splitlines() if "Chicken fried rice" in ln))
    with Session(ctx.engine) as s:
        a = pending.latest(s, household(ctx).id, pending.YES_NO_KINDS)
        assert a.kind == "recipe_missing"
        title, detail, money = describe(s, household(ctx), a)
    assert "Chicken fried rice" in title and detail == "frozen peas" and money is False


# ---------- family group chat ----------

@pytest.fixture
def family(seeded):
    ctx = seeded
    text(ctx, "hi")
    text(ctx, "my name is Alex")
    text(ctx, "hi", handle=SAM)
    text(ctx, "call me Sam", handle=SAM)
    return ctx


def test_group_on_a_shared_line_texts_instructions(family):
    reply = text(family, "group")
    assert reply.startswith("👪 Get the household in one chat:")
    assert "start a new group with Sam (555) 555-0199 and me at (555) 010-0000" in reply
    assert "say hi to everyone by name" in reply
    assert family.photon.outbox[-1]["spaceId"] == family.photon.space_for(HANDLE)  # only the 1:1 chat


def test_group_alone_says_to_invite_first(seeded):
    text(seeded, "hi")
    reply = text(seeded, "group")
    assert "your family or roommates" in reply and "INVITE" in reply


def test_group_on_a_dedicated_line_creates_it(family):
    ctx = family
    ctx.settings.photon_dedicated_line = True
    ctx.photon.dedicated = True
    text(ctx, "invite Mom (469) 555-0123")
    assert text(ctx, "group") == "✅ Started a group chat with Sam and Mom and me. Say hi there!"
    with Session(ctx.engine) as s:
        space = s.exec(select(HouseholdSpace)).one()
    hello = [m for m in ctx.photon.outbox if m["spaceId"] == space.space_id]
    assert hello and hello[0]["text"].startswith("👋 Hi Alex, Sam and Mom!")
    assert sorted(ctx.photon.participants[space.space_id]) == sorted([HANDLE, SAM, MOM])
    # The group is linked: Sam's message there is answered, and Mom joins on her first message.
    name = ",".join(sorted([HANDLE, SAM, MOM]))
    assert "list is empty" in group_say(ctx, SAM, "list", group=name)
    assert group_say(ctx, MOM, "hi", group=name).startswith("👋 Hi Mom! I'm DigiFridgey. Alex added you")


def test_dedicated_setting_falls_back_when_photon_refuses(family):
    family.settings.photon_dedicated_line = True  # but the line is shared: Photon refuses
    assert text(family, "group").startswith("👪 Get the household in one chat:")


def test_first_group_message_greets_everyone_by_name(family):
    ctx = family
    text(ctx, "invite Jordan +15555550177")
    ctx.photon.inject(HANDLE, "hi", created_at=BASE, group="fam", members=[SAM, JORDAN, STRANGER])
    reply = group_say(ctx, HANDLE, "hi fridge", group="fam")
    assert reply.startswith("👋 Hi Alex, Sam and Jordan! This group is now")
    assert "fridge chat" in reply and "I don't know (555) 555-0111 yet" in reply


def test_group_inside_the_group(family):
    group_say(family, HANDLE, "hi")
    assert group_say(family, SAM, "group").startswith("✅ This chat is already")


def test_invite_then_they_text_one_to_one(family):
    ctx = family
    reply = text(ctx, "invite Mom (469) 555-0123")
    assert reply.startswith("✅ Mom ((469) 555-0123) is invited to") and "text me at (555) 010-0000" in reply
    hello = text(ctx, "hi", handle=MOM)
    assert hello.startswith("👋 Hi Mom! I'm DigiFridgey. Alex added you to")
    with Session(ctx.engine) as s:
        mom = s.exec(select(Member).where(Member.photon_handle == MOM)).one()
        alex = s.exec(select(Member).where(Member.photon_handle == HANDLE)).one()
        assert mom.household_id == alex.household_id and mom.display_name == "Mom"
        assert s.get(HouseholdInvite, MOM).member_id == mom.id
    assert "Your fridge" in text(ctx, "fridge", handle=MOM)


def test_invited_person_joins_from_the_group(family):
    ctx = family
    group_say(ctx, HANDLE, "hi")
    text(ctx, "invite Jordan +15555550177")
    reply = group_say(ctx, JORDAN, "what's on the list?")
    assert reply.startswith("👋 Hi Jordan! I'm DigiFridgey. Alex added you")
    assert "list is empty" in reply  # and their message is answered too


def test_invite_checks(family, monkeypatch):
    ctx = family
    assert "doesn't look like a phone number" in text(ctx, "invite 12345678")
    assert "That's your number" in text(ctx, f"invite {HANDLE}")
    assert "Sam is already in" in text(ctx, "invite +15555550199")
    # Someone with their own household can't be pulled into another one.
    from app.signup import sign_up
    run(sign_up(ctx, "Pat", None, "+15555550144"))
    assert "already has its own DigiFridgey household" in text(ctx, "invite +15555550144")


def test_guests_cant_move_money(family):
    ctx = family
    text(ctx, "invite Jordan +15555550177")
    text(ctx, "hi", handle=JORDAN)
    hh = household(ctx)
    with Session(ctx.engine) as s:
        a = pending.create(s, hh.id, "transfer", {"amount": 5.0}, ctx.clock.now())
        s.commit()
        action_id = a.id
    assert "Only the account holder can move money" in text(ctx, "YES", handle=JORDAN)
    assert "Only the account holder" in text(ctx, "settle", handle=JORDAN)
    assert "Only the account holder" in text(ctx, "budget 80", handle=JORDAN)
    with Session(ctx.engine) as s:
        assert s.get(PendingAction, action_id).status == "open"
    assert "Only the account holder" not in text(ctx, "YES")  # Alex is the account holder


def test_money_yes_in_group_still_refused(family):
    ctx = family
    group_say(ctx, HANDLE, "hi")
    with Session(ctx.engine) as s:
        pending.create(s, household(ctx).id, "transfer", {"amount": 5.0}, ctx.clock.now())
        s.commit()
    assert "Money only moves" in group_say(ctx, HANDLE, "YES")


def test_mock_text_endpoint_with_group_and_members(family):
    c = TestClient(create_app(family))
    r = c.post("/demo/mock/text", json={"handle": HANDLE, "text": "hi", "group": "house",
                                        "members": [SAM, STRANGER]}).json()
    assert r["conversation"][-1]["text"].startswith("👋 Hi Alex and Sam!")
    r = c.post("/demo/mock/text", json={"handle": SAM, "text": "what can I make?", "group": "house"}).json()
    assert "fridge is empty" in r["conversation"][-1]["text"]
    r = c.post("/demo/mock/text", json={"handle": STRANGER, "text": "hello?", "group": "house"}).json()
    assert "only answer people in the household" in r["conversation"][-1]["text"]
