"""Presenter remote control. Mounted only when DEMO_MODE=true.
If DEMO_TOKEN is set, requests need header X-Demo-Token (or ?token=)."""
from __future__ import annotations

import hmac
from pathlib import Path

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from fastapi.responses import HTMLResponse
from pydantic import BaseModel
from sqlmodel import Session, select

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


def require_token(request: Request) -> None:
    token = request.app.state.ctx.settings.demo_token
    if not token:
        return
    given = request.headers.get("x-demo-token") or request.query_params.get("token") or ""
    if not hmac.compare_digest(given, token):
        raise HTTPException(401, "bad demo token")


router = APIRouter(prefix="/demo", dependencies=[Depends(require_token)])
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


@page_router.get("/demo", response_class=HTMLResponse)
async def demo_page() -> str:
    return (Path(__file__).parent / "static" / "demo.html").read_text()


@router.post("/buy")
async def buy(request: Request, basket: str = Query("weekly"), household_id: int | None = None):
    ctx = _ctx(request)
    if basket not in DATA["baskets"]:
        raise HTTPException(400, f"unknown basket; choose from {sorted(DATA['baskets'])}")
    hh = await _demo_hh(ctx, household_id)
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
async def advance(request: Request, days: float = 0, hours: float = 0):
    ctx = _ctx(request)
    ctx.clock.advance(days=days, hours=hours)
    await sync_now(ctx)
    summary = await tick_now(ctx)
    return {"now_local": ctx.clock.local_now().isoformat(timespec="minutes"),
            "offset_hours": ctx.clock.offset.total_seconds() / 3600, **summary}


@router.post("/sweep")
async def sweep(request: Request, household_id: int | None = None):
    ctx = _ctx(request)
    hh = await _demo_hh(ctx, household_id)
    text = await offer_sweep(ctx, hh, f"sweep:manual:{ctx.clock.real_now().timestamp():.0f}")
    return {"sent": text}


@router.post("/tick")
async def tick(request: Request):
    ctx = _ctx(request)
    await sync_now(ctx)
    return await tick_now(ctx)


@router.post("/reset")
async def reset(request: Request, wipe_nessie: bool = False):
    """Fresh local state and a fresh demo customer. wipe_nessie=true also deletes
    Customers/Accounts/Purchases/Transfers for the whole Nessie key."""
    ctx = _ctx(request)
    keep = ("nessie_objects", "processed_messages", "photon_cursor")
    clear_all(ctx.engine, keep=keep)
    ctx.clock.reset()
    reset_salt(ctx)
    if wipe_nessie:
        for t in ("Purchases", "Transfers", "Accounts", "Customers"):
            try:
                await ctx.nessie.delete_data(t)
            except Exception as exc:  # report, keep going
                return {"error": f"Nessie delete {t} failed: {exc}"}
    bump_generation(ctx)  # new synthetic customer, so old purchases don't reappear
    if ctx.photon.is_mock:
        ctx.photon.inbox.clear()
        ctx.photon.outbox.clear()
    hh = await seed(ctx)
    return {"household": hh.name, "checking": hh.checking_account_id, "grocery_fund": hh.grocery_fund_account_id}


class MockText(BaseModel):
    handle: str = "+15555550123"
    text: str


@router.post("/mock/text")
async def mock_text(request: Request, body: MockText):
    """SIMULATED inbound iMessage (mock Photon only)."""
    ctx = _ctx(request)
    if not ctx.photon.is_mock:
        raise HTTPException(400, "Photon is live; text the agent from a real phone")
    ctx.photon.inject(body.handle, body.text)
    await poll_once(ctx)
    return {"conversation": ctx.photon.conversation(body.handle)}


@router.get("/state")
async def state(request: Request, household_id: int | None = None, handle: str | None = None,
                app_household_id: str | None = None):
    """`app_household_id` (from the iPhone app) returns only the bank household that shares that
    app household's fridge, and none if no one has linked a bank to it yet."""
    ctx = _ctx(request)
    if app_household_id:
        from ..spacetime.bridge import household_for_app
        linked = household_for_app(ctx, app_household_id)
        household_id = linked.id if linked else None
    with Session(ctx.engine) as s:
        hh = (s.get(Household, household_id) if household_id else None) if app_household_id \
            else pick_household(s, household_id)
        households = [{"id": h.id, "name": h.name} for h in s.exec(select(Household).order_by(Household.id.desc()))]
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
                "pending": [{"kind": a.kind, "payload": a.payload_json} for a in s.exec(
                    select(PendingAction).where(PendingAction.household_id == hh.id, PendingAction.status == "open"))],
            }
            try:
                out["household"]["checking_balance"] = await running_balance(ctx.nessie, hh.checking_account_id)
                out["household"]["fund_balance"] = await running_balance(ctx.nessie, hh.grocery_fund_account_id)
            except Exception:
                pass
    if ctx.photon.is_mock:
        out["conversation"] = ctx.photon.conversation(handle)
    return out


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
    with Session(ctx.engine) as s:
        hh = s.get(Household, household_id) if household_id else pick_household(s, None)
        if not hh:
            raise HTTPException(404, "no such household")
        return {"purchases": list_purchases(ctx, s, hh.id)}


@router.post("/purchases/{purchase_id}/stock")
async def stock_purchase(request: Request, purchase_id: str, body: StockBody,
                         household_id: int | None = None):
    from .. import card
    from ..photon.outbound import notify_household
    ctx = _ctx(request)
    with Session(ctx.engine) as s:
        hh = s.get(Household, household_id) if household_id else pick_household(s, None)
        if not hh:
            raise HTTPException(404, "no such household")
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
    with Session(ctx.engine) as s:
        hh = s.get(Household, household_id) if household_id else pick_household(s, None)
        if not hh:
            raise HTTPException(404, "no such household")
        n = card.skip_rest(s, hh, purchase_id, ctx.clock.now())
        s.commit()
    return {"skipped": n}
