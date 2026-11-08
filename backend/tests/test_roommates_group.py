"""Roommates who each connected their own card share one app fridge, so they share the group chat too.

Each "Connect your bank" sign-up is its own bank household; the app household code ties them together
(SpacetimeLink.app_household_id). The household group chat treats them as one household for the fridge,
list and claims, while money stays with each account holder in their own 1:1 chat.
"""
import uuid

import pytest
from fastapi.testclient import TestClient
from sqlmodel import Session, select

from app.brain import pending
from app.households import linked_household_ids, same_app_household
from app.main import create_app
from app.models import Household, ListClaim, Member, PendingAction, ShoppingListItem
from app.spacetime.client import MockSpacetimeClient

from .conftest import run

ALEX = "+14695550101"
SAM = "+14695550102"
PAT = "+14695550103"  # signed up on their own, not part of the shared fridge
GROUP = "apt4b"


@pytest.fixture
def roommates(ctx):
    ctx.spacetime = MockSpacetimeClient()
    _, token = run(ctx.spacetime.create_identity())
    run(ctx.spacetime.call(token, "create_household", [str(uuid.uuid4()), "Apartment 4B"]))
    code = run(ctx.spacetime.query(token, "SELECT * FROM my_household"))[0]["invite_code"]
    c = TestClient(create_app(ctx))
    alex = c.post("/signup", json={"first_name": "Alex", "phone": ALEX, "app_invite_code": code}).json()
    sam = c.post("/signup", json={"first_name": "Sam", "phone": SAM, "app_invite_code": code}).json()
    pat = c.post("/signup", json={"first_name": "Pat", "phone": PAT}).json()
    assert alex["app_linked"] is True and sam["app_linked"] is True
    assert len({alex["household_id"], sam["household_id"], pat["household_id"]}) == 3  # three cards
    ctx.ids = {"alex": alex["household_id"], "sam": sam["household_id"], "pat": pat["household_id"]}
    ctx.client = c
    return ctx


def say(ctx, handle: str, body: str, **kw) -> str:
    """Says something in the group; returns the agent's newest message there ("" if it stayed quiet)."""
    before = len(ctx.photon.outbox)
    r = ctx.client.post("/demo/mock/text", json={"handle": handle, "text": body, "group": GROUP, **kw}).json()
    return r["conversation"][-1]["text"] if len(ctx.photon.outbox) > before else ""


def member(ctx, handle: str) -> Member:
    with Session(ctx.engine) as s:
        return s.exec(select(Member).where(Member.photon_handle == handle)).one()


def test_same_app_household_helper(roommates):
    ids = roommates.ids
    with Session(roommates.engine) as s:
        assert same_app_household(s, ids["alex"], ids["sam"])
        assert same_app_household(s, ids["pat"], ids["pat"])
        assert not same_app_household(s, ids["alex"], ids["pat"])
        assert linked_household_ids(s, ids["sam"]) == [ids["sam"], ids["alex"]]
        assert linked_household_ids(s, ids["pat"]) == [ids["pat"]]


def test_greeting_names_roommates_with_their_own_card(roommates):
    hello = say(roommates, ALEX, "hi", members=[SAM, PAT])
    assert hello.startswith("👋 Hi Alex and Sam!")
    assert "I don't know (469) 555-0103 yet" in hello and "555-0102" not in hello


def test_both_roommates_get_answers_in_the_group(roommates):
    ctx = roommates
    say(ctx, ALEX, "hi", members=[SAM])
    assert "list is empty" in say(ctx, SAM, "list")
    assert "milk" in say(ctx, SAM, "add milk").lower()
    assert "milk" in say(ctx, ALEX, "list").lower()
    assert "fridge" in say(ctx, SAM, "fridge").lower()
    # One shared list: Sam's add landed in the group's household (Alex linked it), not a second list.
    with Session(ctx.engine) as s:
        rows = list(s.exec(select(ShoppingListItem).where(ShoppingListItem.name.contains("milk"))))
    assert [r.household_id for r in rows] == [ctx.ids["alex"]]
    # Every reply went to the group, nobody's 1:1 chat.
    space = ctx.photon.group_conversation(GROUP)
    assert len(space) == 5


def test_claim_by_the_roommate_shows_their_name(roommates):
    ctx = roommates
    say(ctx, ALEX, "hi", members=[SAM])
    assert say(ctx, ALEX, "who's grabbing milk?").startswith("🛒 Alex asks: who's grabbing")
    assert say(ctx, SAM, "I will").startswith("🙌 Sam's grabbing")
    with Session(ctx.engine) as s:
        claim = s.exec(select(ListClaim)).one()
    assert claim.name == "Sam" and claim.member_id == member(ctx, SAM).id
    # And Alex can't take it over by asking again.
    assert "Sam already said they'd grab" in say(ctx, ALEX, "who's grabbing milk?")


def test_money_yes_in_the_group_is_still_refused(roommates):
    ctx = roommates
    say(ctx, ALEX, "hi", members=[SAM])
    with Session(ctx.engine) as s:
        theirs = pending.create(s, ctx.ids["alex"], "transfer", {"amount": 12.0}, ctx.clock.now())
        mine = pending.create(s, ctx.ids["sam"], "transfer", {"amount": 9.0}, ctx.clock.now())
        s.commit()
        ids = (theirs.id, mine.id)
    assert "Money only moves" in say(ctx, SAM, "YES")
    assert "Money only moves" in say(ctx, ALEX, "YES")
    with Session(ctx.engine) as s:
        assert [s.get(PendingAction, i).status for i in ids] == ["open", "open"]


def test_money_commands_from_a_roommate_use_their_own_bank(roommates):
    ctx = roommates
    say(ctx, ALEX, "hi", members=[SAM])
    say(ctx, SAM, "budget 80")
    with Session(ctx.engine) as s:
        assert s.get(Household, ctx.ids["sam"]).weekly_budget == 80
        assert s.get(Household, ctx.ids["alex"]).weekly_budget != 80


def test_unrelated_household_is_still_ignored(roommates):
    ctx = roommates
    say(ctx, ALEX, "hi", members=[SAM, PAT])
    assert say(ctx, PAT, "list") == ""
    assert say(ctx, PAT, "add cake") == ""
    with Session(ctx.engine) as s:
        assert not list(s.exec(select(ShoppingListItem).where(ShoppingListItem.name.contains("cake"))))


def test_invite_a_roommate_says_theyre_already_in(roommates):
    ctx = roommates
    say(ctx, ALEX, "hi", members=[SAM])
    assert "Sam is already in this group" in say(ctx, ALEX, "invite +14695550102")
    assert "already has its own DigiFridgy household" in say(ctx, ALEX, "invite +14695550103")


def test_group_command_lists_roommates(roommates):
    ctx = roommates
    say(ctx, ALEX, "hi", members=[SAM])
    assert "Household: Alex and Sam." in say(ctx, SAM, "group")
