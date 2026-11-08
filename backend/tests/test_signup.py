import pytest
from fastapi.testclient import TestClient
from sqlmodel import Session, select

from app.main import create_app
from app.models import Household, Member
from app.photon.inbound import handle_raw
from app.signup import normalize_handle, sign_up

from .conftest import BASE, run


@pytest.mark.parametrize("raw,want", [
    ("(469) 555-0123", "+14695550123"), ("469.555.0123", "+14695550123"), ("1 469 555 0123", "+14695550123"),
    ("+44 20 7946 0958", "+442079460958"), ("Alex@iCloud.com", "alex@icloud.com"),
    ("555-0123", None), ("hello", None), ("", None), ("+0123", None),
])
def test_normalize_handle(raw, want):
    assert normalize_handle(raw) == want


def test_signup_creates_household_and_assigns_line(ctx):
    r = run(sign_up(ctx, "Maya", "Chen", "(469) 555-0123"))
    assert r.household.name == "Maya's Household (0123)"
    assert r.household.checking_account_id and r.household.grocery_fund_account_id
    assert r.member.photon_handle == "+14695550123"
    assert r.line == ctx.photon.agent_handle and r.member.assigned_line == r.line
    assert ctx.photon.assignments["+14695550123"]["handle"] == "+14695550123"
    # Each sign-up is its own synthetic Nessie customer.
    customers = run(ctx.nessie.get_customers())
    assert [(c["first_name"], c["last_name"]) for c in customers] == [("Maya", "Chen")]


def test_signup_is_idempotent_per_phone(ctx):
    a = run(sign_up(ctx, "Maya", None, "469-555-0123"))
    b = run(sign_up(ctx, "Maya", None, "+1 (469) 555-0123"))
    assert b.existing and a.household.id == b.household.id
    assert len(ctx.photon.assignments) == 1
    with Session(ctx.engine) as s:
        assert len(s.exec(select(Household)).all()) == 1


def test_bad_phone_rejected(ctx):
    with pytest.raises(ValueError):
        run(sign_up(ctx, "Maya", None, "12345"))


def test_first_text_after_signup_gets_welcome_and_links_space(ctx):
    run(sign_up(ctx, "Maya", None, "4695550123"))
    raw = ctx.photon.inject("+14695550123", "fridge", created_at=BASE)
    assert run(handle_raw(ctx, raw)) is True
    assert ctx.photon.outbox[-1]["text"].startswith("👋 Hi! I'm DigiFridgy")
    assert "Maya's Household (0123)" in ctx.photon.outbox[-1]["text"]
    with Session(ctx.engine) as s:
        m = s.exec(select(Member)).one()
        assert m.photon_space_id == raw["space"]["id"] and m.welcomed
    # The next text is handled normally.
    raw2 = ctx.photon.inject("+14695550123", "fridge", created_at=BASE)
    run(handle_raw(ctx, raw2))
    assert "Your fridge" in ctx.photon.outbox[-1]["text"]


def test_messages_to_an_assigned_pool_line_pass_the_guard(ctx):
    """Pooled lines differ per person; a message to any assigned line is ours."""
    ctx.photon.agent_handle = "+15550109999"  # Photon gives this sign-up a different pool number
    run(sign_up(ctx, "Maya", None, "4695550123"))
    raw = ctx.photon.inject("+14695550123", "hi", created_at=BASE)
    assert raw["receivedBy"]["handle"] != ctx.settings.photon_agent_handle
    assert run(handle_raw(ctx, raw)) is True


def test_line_error_is_reported(ctx):
    async def boom(*a, **k):
        raise RuntimeError("POST /assignments -> 403 (request x): forbidden")
    ctx.photon.assign_line = boom
    r = run(sign_up(ctx, "Maya", None, "4695550123"))
    assert "platforms:write" in r.line_error
    assert r.line == ctx.settings.photon_agent_handle  # falls back to the configured line


def test_signup_http(ctx):
    c = TestClient(create_app(ctx))
    assert "Create my fridge" in c.get("/signup").text
    r = c.post("/signup", json={"first_name": "Maya", "phone": "(469) 555-0123"})
    assert r.status_code == 200 and r.json()["text_this_number"] == ctx.photon.agent_handle
    assert c.post("/signup", json={"first_name": "Maya", "phone": "nope"}).status_code == 400
    # Demo controls default to the newest signed-up household.
    st = c.get("/demo/state").json()
    assert st["household"]["name"] == "Maya's Household (0123)" and st["handle"] == "+14695550123"


def test_signup_requires_token_when_set(ctx):
    ctx.settings.demo_token = "tok"
    c = TestClient(create_app(ctx))
    body = {"first_name": "Maya", "phone": "(469) 555-0123"}
    assert c.post("/signup", json=body).status_code == 401
    assert c.post("/signup", json=body, headers={"x-demo-token": "tok"}).status_code == 200
