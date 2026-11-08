"""Presenter remote control and the app's bank endpoints. Mounted only when DEMO_MODE=true.

Every route needs the demo token (header X-Demo-Token) when DEMO_TOKEN is set, and only answers
loopback requests when it isn't (see `app.auth`). Routes that touch one household's money or data
take that household from the app caller's SpacetimeDB token, never from the query string; the
operator (loopback, or X-Admin-Token) may still pick any household for the demo page."""
from __future__ import annotations

from pathlib import Path

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from fastapi.responses import HTMLResponse
from pydantic import BaseModel
from sqlmodel import Session, select

from ..auth import AppCaller, app_caller, is_operator, require_demo_token, require_operator
from ..brain import copy
from ..db import clear_all
from ..households import demo_household
from ..models import Household, Item, Member, PendingAction, ShoppingListItem, SpacetimeLink, WasteEntry
from ..nessie.banking import insight, offer_sweep
from ..nessie.client import running_balance
from ..nessie.sync import sync_now
from ..photon.inbound import poll_once
from ..photon.outbound import reset_salt
from ..scheduler.jobs import tick_now
from .seed import DATA, bump_generation, create_basket_purchase, seed


router = APIRouter(prefix="/demo", dependencies=[Depends(require_demo_token)])
page_router = APIRouter()


def _ctx(request: Request):
    return request.app.state.ctx


def pick_household(s: Session, household_id: int | None) -> Household | None:
    """Explicit ID, else the newest household someone signed up or texted into, else the seeded demo one."""
    if household_id:
        return s.get(Household, household_id)
    newest = s.exec(select(Household).join(Member, Member.household_id == Household.id)
                    .order_by(Household.id.desc())).first()
    return newest or demo_household(s)


async def _demo_hh(ctx, household_id: int | None = None) -> Household:
    with Session(ctx.engine) as s:
        hh = pick_household(s, household_id)
    if household_id and not hh:
        raise HTTPException(404, "no such household")
    return hh or await seed(ctx)


async def bank_household(request: Request, household_id: int | None = None) -> Household:
    """The bank household this request acts on: the app caller's own bank, or (operator only) any."""
    ctx = _ctx(request)
    caller = await app_caller(request, required=False)
    if caller is not None:
        if caller.bank_household_id is None:
            raise HTTPException(404, "Connect your bank first.")
        if household_id and household_id != caller.bank_household_id:
            raise HTTPException(403, "That's not your bank.")
        with Session(ctx.engine) as s:
            hh = s.get(Household, caller.bank_household_id)
        if hh is None:
            raise HTTPException(404, "Connect your bank first.")
        return hh
    if is_operator(request):
        return await _demo_hh(ctx, household_id)
    raise HTTPException(401, "Sign in to the app first (missing app token).")


async def app_scope(request: Request, app_household_id: str) -> AppCaller | None:
    """The verified app caller, who must belong to `app_household_id`; None for the operator."""
    caller = await app_caller(request, required=False)
    if caller is not None:
        if caller.app_household_id != app_household_id:
            raise HTTPException(403, "You're not in that household.")
        return caller
    if is_operator(request):
        return None
    raise HTTPException(401, "Sign in to the app first (missing app token).")


@page_router.get("/demo", response_class=HTMLResponse)
async def demo_page() -> str:
    return (Path(__file__).parent / "static" / "demo.html").read_text()


@router.post("/buy")
async def buy(request: Request, basket: str = Query("weekly"), household_id: int | None = None):
    ctx = _ctx(request)
    if basket not in DATA["baskets"]:
        raise HTTPException(400, f"unknown basket; choose from {sorted(DATA['baskets'])}")
    hh = await bank_household(request, household_id)
    pid = await create_basket_purchase(ctx, hh.checking_account_id, basket)
    processed = await sync_now(ctx)  # don't wait for the 5 s loop
    await _sync_app(ctx)
    return {"purchase_id": pid, "basket": basket, "processed": processed,
            "simulated": ctx.nessie.is_mock}


async def _sync_app(ctx) -> None:
    """Pushes changes to the app's shared fridge now instead of on the next 3 s round."""
    if ctx.spacetime is None:
        return
    from ..spacetime.bridge import sync_now as sync_app
    try:
        await sync_app(ctx)
    except Exception:  # the background loop retries
        pass


@router.post("/advance")
async def advance(request: Request, days: float = Query(0, ge=0, le=60), hours: float = Query(0, ge=0, le=24 * 60)):
    """Time only moves forward: a rewind would reopen offers that already expired."""
    ctx = _ctx(request)
    try:
        ctx.clock.advance(days=days, hours=hours)
    except (RuntimeError, ValueError) as exc:
        raise HTTPException(422, str(exc))
    await sync_now(ctx)
    summary = await tick_now(ctx)
    return {"now_local": ctx.clock.local_now().isoformat(timespec="minutes"),
            "offset_hours": ctx.clock.offset.total_seconds() / 3600, **summary}


@router.post("/sweep")
async def sweep(request: Request, household_id: int | None = None):
    ctx = _ctx(request)
    hh = await bank_household(request, household_id)
    text = await offer_sweep(ctx, hh, f"sweep:manual:{ctx.clock.real_now().timestamp():.0f}")
    return {"sent": text}


@router.post("/tick")
async def tick(request: Request):
    ctx = _ctx(request)
    await sync_now(ctx)
    return await tick_now(ctx)


@router.post("/reset", dependencies=[Depends(require_operator)])
async def reset(request: Request, wipe_nessie: bool = False):
    """Fresh local state and a fresh demo customer. wipe_nessie=true also deletes
    Customers/Accounts/Purchases/Transfers for the whole Nessie key, so it needs ADMIN_TOKEN."""
    ctx = _ctx(request)
    if wipe_nessie:
        if not ctx.settings.admin_token:
            raise HTTPException(403, "Wiping Nessie deletes everything for the API key: set ADMIN_TOKEN first.")
        # Nessie first: if it fails, local state is untouched and the reset can simply be retried.
        for t in ("Purchases", "Transfers", "Accounts", "Customers"):
            try:
                await ctx.nessie.delete_data(t)
            except Exception as exc:
                raise HTTPException(502, f"Nessie delete {t} failed, nothing was reset locally: {exc}")
    keep = ("nessie_objects", "processed_messages", "photon_cursor")
    clear_all(ctx.engine, keep=keep)
    ctx.clock.reset()
    reset_salt(ctx)
    bump_generation(ctx)  # new synthetic customer, so old purchases don't reappear
    if ctx.photon.is_mock:
        ctx.photon.inbox.clear()
        ctx.photon.outbox.clear()
    hh = await seed(ctx)
    return {"household": hh.name, "checking": hh.checking_account_id, "grocery_fund": hh.grocery_fund_account_id}


class MockText(BaseModel):
    handle: str = "+15555550123"
    text: str
    group: str | None = None  # name of a simulated group chat, e.g. "flat"


@router.post("/mock/text", dependencies=[Depends(require_operator)])
async def mock_text(request: Request, body: MockText):
    """SIMULATED inbound iMessage (mock Photon only). With `group`, it's said in that group chat."""
    ctx = _ctx(request)
    if not ctx.photon.is_mock:
        raise HTTPException(400, "Photon is live; text the agent from a real phone")
    ctx.photon.inject(body.handle, body.text, group=body.group)
    await poll_once(ctx)
    if body.group:
        return {"conversation": [{"from": "agent", "text": m["text"], "at": m["createdAt"]}
                                 for m in ctx.photon.group_conversation(body.group)]}
    return {"conversation": ctx.photon.conversation(body.handle)}


def bank_for_app_user(ctx, app_household_id: str, app_identity: str | None) -> Household | None:
    """The bank household of this app user (Connect your bank), else the newest bank linked to their fridge."""
    from ..models import AppMember
    from ..money import norm_identity
    from ..spacetime.bridge import household_for_app
    with Session(ctx.engine) as s:
        if app_identity:
            m = s.get(AppMember, norm_identity(app_identity))
            link = s.get(SpacetimeLink, m.household_id) if m else None
            if link and link.app_household_id == app_household_id:
                return s.get(Household, m.household_id)
    return household_for_app(ctx, app_household_id)


@router.get("/state")
async def state(request: Request, household_id: int | None = None, handle: str | None = None,
                app_household_id: str | None = None, app_identity: str | None = None):
    """`app_household_id` (from the iPhone app) returns only the bank household that shares that
    app household's fridge, and none if no one has linked a bank to it yet. With `app_identity`,
    it's that app user's own bank (roommates each connect their own)."""
    ctx = _ctx(request)
    operator = False
    if app_household_id:
        caller = await app_scope(request, app_household_id)
        if caller is not None:
            app_identity = caller.identity  # never another person's identity from the query
            handle = None
        linked = bank_for_app_user(ctx, app_household_id, app_identity)
        household_id = linked.id if linked else None
    else:
        require_operator(request)  # the demo page: any household, any conversation
        operator = True
    with Session(ctx.engine) as s:
        hh = (s.get(Household, household_id) if household_id else None) if app_household_id \
            else pick_household(s, household_id)
        households = ([{"id": h.id, "name": h.name} for h in s.exec(select(Household).order_by(Household.id.desc()))]
                      if operator else [])
        if hh and not handle:
            first = s.exec(select(Member).where(Member.household_id == hh.id).order_by(Member.id)).first()
            handle = first.photon_handle if first else None
        handle = handle or "+15555550123"
        member = s.exec(select(Member).where(Member.photon_handle == handle)).first()
        out = {
            "now_local": ctx.clock.local_now().strftime("%a %b %-d, %-I:%M %p"),
            "offset_days": round(ctx.clock.offset.total_seconds() / 86400, 2),
            "mock_nessie": ctx.nessie.is_mock, "mock_photon": ctx.photon.is_mock, "llm": ctx.llm is not None,
            "household": None, "households": households, "handle": handle,
            "line": member.assigned_line if member else None,
        }
        if hh:
            fresh = list(s.exec(select(Item).where(Item.household_id == hh.id, Item.status == "fresh")
                                .order_by(Item.expires_at)))
            ins = insight(ctx, s, hh)
            out["household"] = {
                "id": hh.id, "name": hh.name, "budget": hh.weekly_budget,
                "app_household_id": _app_household_id(s, hh.id),
                "members": [m.photon_handle + (f" → texts {m.assigned_line}" if m.assigned_line else "")
                            + ("" if m.status == "active" else " (stopped)")
                            for m in s.exec(select(Member).where(Member.household_id == hh.id))],
                "fridge": [{"name": i.name, "emoji": i.emoji, "expires": copy.day_label(i.expires_at, ctx.clock),
                            "price": i.price} for i in fresh],
                "list": [r.name + ("" if r.confirmed else " (suggested)")
                         for r in s.exec(select(ShoppingListItem).where(ShoppingListItem.household_id == hh.id,
                                                                        ShoppingListItem.done == False))],  # noqa: E712
                "waste_total": round(sum(w.amount for w in s.exec(select(WasteEntry).where(
                    WasteEntry.household_id == hh.id))), 2),
                "week_spend": ins.week_spend, "week_waste": ins.week_waste,
                "streak": _streak(ctx, s, hh),
                "pending": [{"kind": a.kind, "payload": a.payload_json} for a in s.exec(
                    select(PendingAction).where(PendingAction.household_id == hh.id, PendingAction.status == "open"))],
            }
            try:
                out["household"]["checking_balance"] = await running_balance(ctx.nessie, hh.checking_account_id)
                out["household"]["fund_balance"] = await running_balance(ctx.nessie, hh.grocery_fund_account_id)
            except Exception:
                pass
    if ctx.photon.is_mock and (operator or (hh and member and member.household_id == hh.id)):
        out["conversation"] = ctx.photon.conversation(handle)
    return out


def _streak(ctx, s: Session, hh: Household) -> dict:
    from ..money import budget_streak
    st = budget_streak(ctx, s, hh)
    return {"weeks": st.weeks, "saved": st.saved, "week_left": st.week_left, "waste_trend": st.waste_trend}


def _app_household_id(s: Session, household_id: int) -> str | None:
    link = s.get(SpacetimeLink, household_id)
    return (link.app_household_id or None) if link else None


# ---------- Add from card (the app's + menu) ----------

class StockBody(BaseModel):
    lines: list[int] | None = None  # line indexes to add; omitted = every pending line


@router.get("/purchases")
async def purchases(request: Request, household_id: int | None = None):
    """Recent grocery card purchases with their products, and which ones are already in the fridge."""
    from ..card import list_purchases
    ctx = _ctx(request)
    hh = await bank_household(request, household_id)
    with Session(ctx.engine) as s:
        from ..money import purchase_breakdown
        out = list_purchases(ctx, s, hh.id)
        for p in out:
            p["breakdown"] = purchase_breakdown(s, hh.id, p["purchase_id"], p["amount"])
        return {"purchases": out}


@router.post("/purchases/{purchase_id}/stock")
async def stock_purchase(request: Request, purchase_id: str, body: StockBody,
                         household_id: int | None = None):
    from .. import card
    from ..photon.outbound import notify_household
    ctx = _ctx(request)
    hh = await bank_household(request, household_id)
    with Session(ctx.engine) as s:
        hh = s.get(Household, hh.id)
        fresh = card.stock_lines(ctx, s, hh, purchase_id, body.lines)
        s.commit()
        names = sorted({i.name for i in fresh})
        hh_id = hh.id
    await _sync_app(ctx)
    if fresh:
        # Keep the iMessage thread in step with what was picked in the app.
        await notify_household(ctx, hh_id, f"🧊 Added {len(fresh)} items from the app: {', '.join(names[:4])}"
                               + (" …" if len(names) > 4 else ""),
                               f"cardadd:{purchase_id}:{ctx.clock.real_now().timestamp():.0f}")
    return {"added": len(fresh), "names": names}


@router.post("/purchases/{purchase_id}/skip")
async def skip_purchase(request: Request, purchase_id: str, household_id: int | None = None):
    from .. import card
    ctx = _ctx(request)
    hh = await bank_household(request, household_id)
    with Session(ctx.engine) as s:
        hh = s.get(Household, hh.id)
        n = card.skip_rest(s, hh, purchase_id, ctx.clock.now())
        s.commit()
    return {"skipped": n}


# ---------- roommates: settle-up ----------

def _debt_json(state, d) -> dict:
    return {"from_id": d.from_id, "to_id": d.to_id, "from_name": state.name(d.from_id), "to_name": state.name(d.to_id),
            "amount": d.amount, "items": d.items[:5]}


@router.get("/settle")
async def settle(request: Request, app_household_id: str, household_id: int | None = None):
    """Who owes whom among the roommates (bank households) sharing this app household's fridge."""
    from ..money import settle_state
    ctx = _ctx(request)
    caller = await app_scope(request, app_household_id)
    if caller is not None:
        household_id = caller.bank_household_id
    state = await settle_state(ctx, app_household_id)
    return {"me": household_id, "app_uses_available": state.app_uses_available,
            "roommates": [{"id": r.household_id, "name": r.name} for r in state.roommates.values()],
            "debts": [_debt_json(state, d) for d in state.debts]}


@router.post("/settle/pay")
async def settle_pay(request: Request, app_household_id: str, to: int, household_id: int | None = None,
                     quoted_amount: int | None = Query(None, ge=1)):
    """The app user confirmed paying a roommate `quoted_amount` (the whole dollars the dialog showed):
    a Nessie transfer from the caller's own checking account. The payer is always the caller."""
    from ..money import pay
    ctx = _ctx(request)
    caller = await app_scope(request, app_household_id)
    if caller is not None:
        if caller.bank_household_id is None:
            raise HTTPException(404, "Connect your bank first.")
        if household_id and household_id != caller.bank_household_id:
            raise HTTPException(403, "You can only pay from your own bank.")
        household_id = caller.bank_household_id
    elif household_id is None:
        raise HTTPException(400, "household_id is required")
    with Session(ctx.engine) as s:
        ids = _roommate_ids(s, app_household_id)
    if household_id not in ids or to not in ids:
        raise HTTPException(404, "not a roommate in this fridge")
    ok, message = await pay(ctx, app_household_id, household_id, to, quoted=quoted_amount,
                            claim_key=request.headers.get("idempotency-key"))
    return {"ok": ok, "message": message}


@router.post("/settle/ask")
async def settle_ask(request: Request, app_household_id: str, debtor: int, household_id: int | None = None):
    """Texts a roommate who owes the caller their split, with a YES to pay."""
    from ..money import request_payment
    ctx = _ctx(request)
    caller = await app_scope(request, app_household_id)
    if caller is not None:
        if caller.bank_household_id is None:
            raise HTTPException(404, "Connect your bank first.")
        household_id = caller.bank_household_id
    elif household_id is None:
        raise HTTPException(400, "household_id is required")
    with Session(ctx.engine) as s:
        ids = _roommate_ids(s, app_household_id)
    if debtor not in ids or household_id not in ids:
        raise HTTPException(404, "not a roommate in this fridge")
    return {"message": await request_payment(ctx, app_household_id, debtor, household_id)}


def _roommate_ids(s: Session, app_household_id: str) -> set[int]:
    return {l.household_id for l in s.exec(select(SpacetimeLink).where(
        SpacetimeLink.app_household_id == app_household_id))}


@router.post("/roommate")
async def add_roommate(request: Request, app_household_id: str, name: str = "Sam", basket: str = "weekly"):
    """Demo: a second roommate with their own synthetic Nessie customer joins this fridge and buys
    groceries on their card, so settle-up has two people. No iMessage line is assigned."""
    from .. import card
    from ..households import provision_household
    from ..spacetime.bridge import join_app_household
    ctx = _ctx(request)
    await app_scope(request, app_household_id)
    if basket not in DATA["baskets"]:
        raise HTTPException(400, f"unknown basket; choose from {sorted(DATA['baskets'])}")
    with Session(ctx.engine) as s:
        code = next((l.invite_code for l in s.exec(select(SpacetimeLink).where(
            SpacetimeLink.app_household_id == app_household_id)) if l.invite_code), None)
    if not code:
        raise HTTPException(404, "connect a bank to this fridge first")
    name = (name.strip() or "Sam")[:20]
    hh = await provision_household(ctx, f"{name}'s Household (roommate)", name, "Roommate", is_demo=False,
                                   key=f"roommate:{app_household_id}:{name.lower()}", lookup_by_name=False)
    ok, msg = await join_app_household(ctx, hh, code)
    if not ok:
        raise HTTPException(502, msg)
    pid = await create_basket_purchase(ctx, hh.checking_account_id, basket)
    await sync_now(ctx)
    with Session(ctx.engine) as s:
        stocked = card.stock_lines(ctx, s, s.get(Household, hh.id), pid)
        s.commit()
    await _sync_app(ctx)
    return {"household_id": hh.id, "name": name, "stocked": len(stocked)}


class UseBody(BaseModel):
    item: str


@router.post("/roommate/use")
async def roommate_uses(request: Request, household_id: int, body: UseBody):
    """Demo: a roommate texts USED <item> (no phone needed)."""
    from ..brain.commands import update_item
    from ..spacetime.bridge import request_sync
    ctx = _ctx(request)
    caller = await app_caller(request, required=False)
    if caller is not None:
        with Session(ctx.engine) as s:
            roommates = _roommate_ids(s, caller.app_household_id) if caller.app_household_id else set()
        if household_id not in roommates:
            raise HTTPException(403, "Not a roommate in your fridge.")
    elif not is_operator(request):
        raise HTTPException(401, "Sign in to the app first (missing app token).")
    reply = update_item(ctx, household_id, body.item, "used")
    await _sync_app(ctx)
    request_sync(ctx)
    return {"reply": reply}
