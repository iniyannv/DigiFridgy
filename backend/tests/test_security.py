"""Who can move money and see data: the fixes from docs/workbench/critiques/digifridgy-project.md."""
import pytest
from fastapi.testclient import TestClient
from sqlmodel import Session, select

from app import money, transfers
from app.auth import clear_cache
from app.brain.commands import answer_yes_no, update_item
from app.brain.router import Intent, route
from app.clock import Clock
from app.households import household_for_new_member
from app.main import create_app
from app.models import ClockOffset, Household, Member, PendingAction, Settlement, TransferClaim
from app.nessie.client import MockNessieClient, NessieError, PartialTransfer
from app.signup import sign_up
from app.spacetime import bridge

from .conftest import BASE, HANDLE, household, outbox_texts, run, text
from .test_money import app_household, app_user_of, buy, flat  # noqa: F401  (fixture)
from .test_sweep import setup_offer
from .test_sweep import transfers as sweep_transfers

REMOTE = {"x-forwarded-for": "203.0.113.9"}


@pytest.fixture(autouse=True)
def _fresh_auth_cache():
    clear_cache()
    yield
    clear_cache()


def client(ctx):
    return TestClient(create_app(ctx))


def owe(ctx, alex, sam):
    """Sam eats Alex's chicken: Sam owes Alex."""
    buy(ctx, alex)
    run(bridge.sync_now(ctx))
    update_item(ctx, sam.id, "chicken", "used")
    run(bridge.sync_now(ctx))


# ---------- B1: demo routes are not open to the network ----------

def test_without_demo_token_only_this_computer_is_served(seeded):
    c = client(seeded)
    assert c.post("/demo/sweep").status_code == 200
    assert c.post("/demo/sweep", headers=REMOTE).status_code == 403
    assert c.post("/signup", json={"first_name": "A", "phone": "4695550100"}, headers=REMOTE).status_code == 403


def test_demo_token_is_header_only(seeded):
    seeded.settings.demo_token = "tok"
    c = client(seeded)
    assert c.post("/demo/sweep?token=tok").status_code == 401
    assert c.post("/demo/sweep", headers={"x-demo-token": "nope"}).status_code == 401


def test_secret_compare_handles_non_ascii():
    from app.auth import same_secret
    assert not same_secret("tök", "tok") and same_secret("tok", "tok")


def test_wiping_nessie_needs_admin_token(seeded):
    c = client(seeded)
    assert c.post("/demo/reset?wipe_nessie=true").status_code == 403
    seeded.settings.admin_token = "adm"
    assert c.post("/demo/reset?wipe_nessie=true").status_code == 403
    assert c.post("/demo/reset?wipe_nessie=true", headers={"x-admin-token": "adm"}).status_code == 200


def test_reset_from_the_network_needs_the_operator(seeded):
    seeded.settings.demo_token = "tok"
    c = client(seeded)
    assert c.post("/demo/reset", headers={"x-demo-token": "tok", **REMOTE}).status_code == 403


def test_state_without_app_household_is_operator_only(seeded):
    seeded.settings.demo_token = "tok"
    c = client(seeded)
    h = {"x-demo-token": "tok"}
    assert c.get("/demo/state", headers={**h, **REMOTE}).status_code == 403
    assert "households" in c.get("/demo/state", headers=h).json()


# ---------- B2 / H1: the payer is the verified caller ----------

def test_settle_pay_takes_the_payer_from_the_app_token(flat):
    ctx, alex, sam, code = flat
    ctx.settings.demo_token = "tok"
    owe(ctx, alex, sam)
    app_hh = app_household(ctx, alex)
    alex_token = app_user_of(ctx, alex, code)
    sam_token = app_user_of(ctx, sam, code)
    c = client(ctx)
    base = {"x-demo-token": "tok", **REMOTE}
    q = {"app_household_id": app_hh, "to": alex.id, "household_id": sam.id}

    # No app token from the network: refused.
    assert c.post("/demo/settle/pay", params=q, headers=base).status_code == 401
    # Alex (the creditor) tries to pay himself out of Sam's checking: refused.
    r = c.post("/demo/settle/pay", params=q, headers={**base, "authorization": f"Bearer {alex_token}"})
    assert r.status_code == 403
    assert ctx.nessie.state["transfers"] == {}
    # Sam pays what he owes, from his own account.
    debt = run(money.settle_state(ctx, app_hh)).debts[0]
    dollars = int(debt.amount)
    r = c.post("/demo/settle/pay", params={**q, "quoted_amount": dollars},
               headers={**base, "authorization": f"Bearer {sam_token}"})
    assert r.status_code == 200 and r.json()["ok"], r.json()
    assert len(ctx.nessie.state["transfers"]) == 1


def test_settle_pay_rejects_a_caller_from_another_household(flat):
    ctx, alex, sam, code = flat
    ctx.settings.demo_token = "tok"
    owe(ctx, alex, sam)
    stranger, token = run(ctx.spacetime.create_identity())
    run(ctx.spacetime.call(token, "create_household", ["other-hh", "Elsewhere"]))
    r = client(ctx).post("/demo/settle/pay", params={"app_household_id": app_household(ctx, alex), "to": alex.id},
                         headers={"x-demo-token": "tok", "authorization": f"Bearer {token}", **REMOTE})
    assert r.status_code == 403


def test_state_for_an_app_household_needs_membership(flat):
    ctx, alex, sam, code = flat
    ctx.settings.demo_token = "tok"
    _, token = run(ctx.spacetime.create_identity())
    run(ctx.spacetime.call(token, "create_household", ["other-hh", "Elsewhere"]))
    c = client(ctx)
    h = {"x-demo-token": "tok", **REMOTE}
    q = {"app_household_id": app_household(ctx, alex)}
    assert c.get("/demo/state", params=q, headers=h).status_code == 401
    assert c.get("/demo/state", params=q, headers={**h, "authorization": f"Bearer {token}"}).status_code == 403
    member_token = app_user_of(ctx, alex, code)
    body = c.get("/demo/state", params=q, headers={**h, "authorization": f"Bearer {member_token}"}).json()
    assert body["households"] == [] and body["household"]["id"] == alex.id


# ---------- B4: pay what was approved ----------

def test_pay_never_sends_more_than_was_approved(flat):
    ctx, alex, sam, _ = flat
    owe(ctx, alex, sam)
    app_hh = app_household(ctx, alex)
    current = int(run(money.settle_state(ctx, app_hh)).debts[0].amount)
    ok, msg = run(money.pay(ctx, app_hh, sam.id, alex.id, quoted=current + 5))
    assert not ok and "changed" in msg and ctx.nessie.state["transfers"] == {}
    ok, _ = run(money.pay(ctx, app_hh, sam.id, alex.id, quoted=current))
    assert ok and list(ctx.nessie.state["transfers"].values())[0]["amount"] == current


def test_yes_pays_the_offered_amount_even_if_the_debt_grew(flat):
    ctx, alex, sam, _ = flat
    owe(ctx, alex, sam)
    run(money.offer(ctx, sam))
    with Session(ctx.engine) as s:
        offered = [a for a in s.exec(select(PendingAction).where(PendingAction.kind == "settle"))][0]
        import json
        amount = json.loads(offered.payload_json)["amount"]
    update_item(ctx, sam.id, "milk", "used")  # the debt grows after the offer (and asks "add milk?")
    run(bridge.sync_now(ctx))
    assert "Sent" not in run(answer_yes_no(ctx, sam, True))  # YES answers the newer milk question first
    assert run(answer_yes_no(ctx, sam, True)).startswith("✅ Sent")
    assert [t["amount"] for t in ctx.nessie.state["transfers"].values()] == [amount]


# ---------- B5: YES answers the right question ----------

def test_a_money_offer_doesnt_replace_a_fridge_question(seeded):
    ctx = seeded
    text(ctx, "hi")
    hh = household(ctx)
    from app.demo.seed import create_basket_purchase
    from app.nessie.banking import offer_sweep
    from app.nessie.sync import sync_now
    run(create_basket_purchase(ctx, hh.checking_account_id, "weekly"))
    run(sync_now(ctx))
    text(ctx, "I finished the milk")              # "add milk to your list?"
    run(offer_sweep(ctx, hh, "sweep:test"))        # a money offer arrives after it
    assert text(ctx, "ok").startswith("🛒 Added whole milk")  # casual yes: the fridge question
    assert sweep_transfers(ctx) == []
    assert "full word YES" in text(ctx, "sure")   # only the money offer is left: casual yes is refused
    assert sweep_transfers(ctx) == []
    assert "Moved" in text(ctx, "YES") or len(sweep_transfers(ctx)) == 1
    assert len(sweep_transfers(ctx)) == 1


def test_settle_offer_is_only_confirmed_by_the_person_who_asked(flat):
    ctx, alex, sam, _ = flat
    owe(ctx, alex, sam)
    with Session(ctx.engine) as s:
        other = Member(household_id=sam.id, photon_handle="+15555550999", created_at=BASE, welcomed=True)
        asker = Member(household_id=sam.id, photon_handle="+15555550998", created_at=BASE, welcomed=True)
        s.add(other)
        s.add(asker)
        s.commit()
        s.refresh(other)
        s.refresh(asker)
    run(money.offer(ctx, sam, member_id=asker.id))
    reply = run(answer_yes_no(ctx, sam, True, member_id=other.id))
    assert "someone else" in reply and ctx.nessie.state["transfers"] == {}
    assert run(answer_yes_no(ctx, sam, True, member_id=asker.id)).startswith("✅ Sent")


def test_llm_can_never_start_a_money_step():
    class FakeLLM:
        def __init__(self, name):
            self.name = name

        async def classify(self, text):
            return Intent(name=self.name, amount=5)

    for name in ("settle", "budget", "yes"):
        assert run(route("please sort out the money thing", FakeLLM(name))).name == "unknown"


# ---------- B6: transfers happen once ----------

class FlakyNessie(MockNessieClient):
    def __init__(self, path, mode):
        super().__init__(path)
        self.mode = mode
        self.deposit_failures = 0

    async def create_transfer(self, from_account_id, to_account_id, amount, description, transaction_date):
        if self.mode == "timeout_after_commit":
            await super().create_transfer(from_account_id, to_account_id, amount, description, transaction_date)
            raise NessieError("POST /transfers: ReadTimeout")
        if self.mode == "deposit_fails":
            tid = self._add("transfers", {"account_id": from_account_id, "transaction_date": transaction_date,
                                          "status": "completed", "amount": int(amount), "description": description})
            raise PartialTransfer(tid, RuntimeError("deposit 503"))
        return await super().create_transfer(from_account_id, to_account_id, amount, description, transaction_date)

    async def create_deposit(self, account_id, amount, description, transaction_date):
        if self.mode == "deposit_fails" and self.deposit_failures < 2:
            self.deposit_failures += 1
            raise NessieError("POST /deposits -> 503", 503)
        return await super().create_deposit(account_id, amount, description, transaction_date)


def _accounts(ctx):
    hh = household(ctx)
    return hh.checking_account_id, hh.grocery_fund_account_id


def test_a_timeout_after_the_bank_committed_is_not_sent_again(seeded, tmp_path):
    ctx = seeded
    flaky = FlakyNessie(str(tmp_path / "nessie.json"), "timeout_after_commit")
    ctx.nessie = flaky
    a, b = _accounts(ctx)
    out = run(transfers.move(ctx, "k1", a, b, 12, "test", "2026-11-07"))
    assert out.status == "done" and len(flaky.state["transfers"]) == 1
    again = run(transfers.move(ctx, "k1", a, b, 12, "test", "2026-11-07"))
    assert again.status == "duplicate" and len(flaky.state["transfers"]) == 1


def test_a_failed_deposit_is_retried_not_the_transfer(seeded, tmp_path):
    ctx = seeded
    flaky = FlakyNessie(str(tmp_path / "nessie.json"), "deposit_fails")
    ctx.nessie = flaky
    a, b = _accounts(ctx)
    out = run(transfers.move(ctx, "k2", a, b, 7, "test", "2026-11-07"))
    assert out.status == "deposit_pending" and out.money_left
    deposits_to_b = [d for d in flaky.state["deposits"].values() if d["account_id"] == b and "dfg:" in d["description"]]
    assert deposits_to_b == []
    assert run(transfers.retry_deposits(ctx)) == 0  # the bank is still failing deposits
    assert run(transfers.retry_deposits(ctx)) == 1
    assert len(flaky.state["transfers"]) == 1
    with Session(ctx.engine) as s:
        assert s.get(TransferClaim, "k2").status == "done"


def test_a_clear_rejection_can_be_retried(seeded):
    ctx = seeded

    class Rejecting(MockNessieClient):
        calls = 0

        async def create_transfer(self, *a, **k):
            Rejecting.calls += 1
            if Rejecting.calls == 1:
                raise NessieError("POST /transfers -> 400: bad", 400)
            return await super().create_transfer(*a, **k)

    ctx.nessie = Rejecting(ctx.settings.mock_nessie_path)
    a, b = _accounts(ctx)
    assert run(transfers.move(ctx, "k3", a, b, 5, "t", "2026-11-07")).status == "failed"
    assert run(transfers.move(ctx, "k3", a, b, 5, "t", "2026-11-07")).status == "done"


def test_settlement_is_recorded_when_only_the_deposit_failed(flat, tmp_path):
    ctx, alex, sam, _ = flat
    owe(ctx, alex, sam)
    real = ctx.nessie
    flaky = FlakyNessie(ctx.settings.mock_nessie_path, "deposit_fails")
    flaky.state = real.state
    ctx.nessie = flaky
    ok, msg = run(money.pay(ctx, app_household(ctx, alex), sam.id, alex.id))
    assert ok and "still going through" in msg
    with Session(ctx.engine) as s:
        assert len(list(s.exec(select(Settlement)))) == 1
    ok, _ = run(money.pay(ctx, app_household(ctx, alex), sam.id, alex.id))
    assert not ok  # square now: never paid twice


# ---------- B3: sign-up can't take over a household ----------

def test_signup_with_a_known_number_asks_the_phone_first(flat):
    ctx, alex, sam, code = flat
    # Alex texts from HANDLE. An attacker signs up with Alex's number and their own fridge code.
    _, attacker = run(ctx.spacetime.create_identity())
    run(ctx.spacetime.call(attacker, "create_household", ["evil-hh", "Evil"]))
    evil_code = ctx.spacetime.households["evil-hh"].invite_code
    r = run(sign_up(ctx, "Mallory", None, HANDLE, evil_code, "ab" * 16))
    assert r.existing and r.app_linked is False and "Reply YES" in r.app_link_message
    assert app_household(ctx, alex) != "evil-hh"
    assert "connect this bank" in outbox_texts(ctx)[-1]
    # The real owner says NO: nothing changes.
    assert "nothing was connected" in text(ctx, "no")
    assert app_household(ctx, alex) != "evil-hh"


def test_an_identity_is_never_moved_to_another_bank(flat):
    from app.models import AppMember
    from app.signup import remember_app_member
    ctx, alex, sam, _ = flat
    ident = "cd" * 16
    assert remember_app_member(ctx, ident, alex.id)
    assert not remember_app_member(ctx, ident, sam.id)
    with Session(ctx.engine) as s:
        assert s.get(AppMember, ident).household_id == alex.id


# ---------- B8: households are keyed on the whole number ----------

def test_same_last_four_digits_are_different_households(ctx):
    ctx.settings.demo_mode = False
    a = run(household_for_new_member(ctx, "+14695550123"))
    b = run(household_for_new_member(ctx, "+12145550123"))
    assert a.id != b.id and a.name == b.name  # same display name, different households
    assert run(household_for_new_member(ctx, "+14695550123")).id == a.id


# ---------- H7: the clock ----------

def test_time_only_moves_forward(seeded):
    c = client(seeded)
    assert c.post("/demo/advance?days=-1").status_code == 422
    with pytest.raises(ValueError):
        seeded.clock.advance(days=-1)


def test_offset_is_ignored_outside_demo_mode(ctx):
    with Session(ctx.engine) as s:
        s.add(ClockOffset(id=1, offset_seconds=86400 * 3))
        s.commit()
    real = Clock(ctx.settings.tz, ctx.engine, base=BASE, time_skip=False)
    assert real.now() == BASE
    with pytest.raises(RuntimeError):
        real.advance(days=1)
    assert Clock(ctx.settings.tz, ctx.engine, base=BASE).now() > BASE


# ---------- H8: STOP ----------

@pytest.mark.parametrize("word", ["STOP", "cancel", "Stop texting me", "opt out", "STOPALL", "revoke", "unsubscribe"])
def test_opt_out_words(seeded, word):
    text(seeded, "hi")
    text(seeded, word)
    with Session(seeded.engine) as s:
        assert s.exec(select(Member).where(Member.photon_handle == HANDLE)).first().status == "stopped"


def test_only_start_opts_back_in_and_stop_closes_offers(seeded):
    ctx = seeded
    setup_offer(ctx)
    text(ctx, "stop")
    with Session(ctx.engine) as s:
        assert not list(s.exec(select(PendingAction).where(PendingAction.status == "open")))
    assert text(ctx, "hi") == ""      # still opted out
    assert text(ctx, "YES") == ""     # and nothing moves
    assert sweep_transfers(ctx) == []
    assert text(ctx, "START") != ""
