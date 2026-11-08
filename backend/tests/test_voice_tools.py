"""Phone calls (Photon number -> ElevenLabs agent -> these tools), looked up by the caller's number."""
from datetime import timedelta

import pytest
from fastapi.testclient import TestClient
from sqlmodel import Session, select

from app.fridge.shelf_life import lookup
from app.main import create_app
from app.models import Item, PendingAction
from app.signup import sign_up

from .conftest import BASE, run, text

H = {"X-Tool-Secret": "s3cret"}


@pytest.fixture
def caller(ctx):
    """A real (non-demo) account: Maya signed up with (469) 555-0123 and has food that's about to go."""
    r = run(sign_up(ctx, "Maya", None, "(469) 555-0123"))
    with Session(ctx.engine) as s:
        for sku, days in {"spinach_5oz": 1, "chicken_breast_2lb": 2, "eggs_dozen": 12, "cheddar_block_16oz": 20}.items():
            info = lookup(sku)
            s.add(Item(household_id=r.household.id, sku=sku, name=info.display_name, category=info.category,
                       location=info.location, emoji=info.emoji, price=3.0, purchased_at=BASE - timedelta(days=1),
                       expires_at=BASE + timedelta(days=days), status="fresh"))
        s.commit()
    text(ctx, "hi", handle="+14695550123")  # she's texted the line, so there's a chat to send to
    ctx.settings.demo_mode = False  # no fallback: the caller's number has to find the household
    ctx.hh_id = r.household.id
    return ctx


@pytest.mark.parametrize("number", ["+14695550123", "14695550123", "(469) 555-0123", "+1 469-555-0123"])
def test_caller_id_in_any_format_finds_the_household(caller, number):
    c = TestClient(create_app(caller))
    r = c.get("/voice/tools/check", params={"item": "spinach", "handle": number}, headers=H)
    assert r.status_code == 200 and r.json()["text"].startswith("Yes, you have")


def test_unknown_caller_gets_404(caller):
    c = TestClient(create_app(caller))
    assert c.get("/voice/tools/fridge", params={"handle": "+15555550000"}, headers=H).status_code == 404


def test_expiring_is_spoken_without_emoji(caller):
    c = TestClient(create_app(caller))
    r = c.get("/voice/tools/expiring", params={"handle": "+14695550123"}, headers=H).json()
    assert r["count"] >= 2 and r["text"].startswith("Use these soon: ")
    assert "spinach" in r["text"] and "chicken" in r["text"] and "Want recipe ideas" in r["text"]
    assert all(ord(ch) < 0x2600 for ch in r["text"])


def test_recipes_by_voice_use_whats_expiring_and_text_the_list(caller):
    ctx = caller
    c = TestClient(create_app(ctx))
    before = len(ctx.photon.outbox)
    r = c.get("/voice/tools/recipes", params={"handle": "+14695550123"}, headers=H).json()
    assert r["count"] >= 1 and r["text"].startswith("You could make ") and "texted you" in r["text"]
    assert all(ord(ch) < 0x2600 for ch in r["text"])
    texts = [m["text"] for m in ctx.photon.outbox[before:]]
    assert texts and texts[-1].startswith("📞 From your call: ⏰ Recipes that use what's about to expire")
    # The texted list is a normal recipe list: replying a number opens one.
    with Session(ctx.engine) as s:
        assert s.exec(select(PendingAction).where(PendingAction.kind == "recipes")).first() is not None


def test_recipes_by_voice_for_one_ingredient(caller):
    c = TestClient(create_app(caller))
    r = c.get("/voice/tools/recipes", params={"handle": "+14695550123", "item": "eggs"}, headers=H).json()
    assert r["count"] >= 1 and "You could make" in r["text"]


def test_browser_test_without_caller_id_uses_newest_signup_in_demo_mode(caller):
    ctx = caller
    ctx.settings.demo_mode = True
    c = TestClient(create_app(ctx))
    for missing in (None, "", "null", "{{system__caller_id}}"):
        params = {} if missing is None else {"handle": missing}
        assert c.get("/voice/tools/expiring", params=params, headers=H).status_code == 200


def test_add_takes_the_caller_from_the_query(caller):
    c = TestClient(create_app(caller))
    r = c.post("/voice/tools/list/add", params={"handle": "+14695550123"}, json={"item": "coffee"}, headers=H)
    assert r.status_code == 200 and "coffee" in r.json()["text"]


def test_caller_in_header(caller):
    c = TestClient(create_app(caller))
    r = c.get("/voice/tools/check", params={"item": "spinach"}, headers={**H, "X-Caller-Id": "+14695550123"})
    assert r.status_code == 200 and r.json()["text"].startswith("Yes, you have")
