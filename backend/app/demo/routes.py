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
from ..models import Household, Item, Member, PendingAction, ShoppingListItem, WasteEntry
from ..nessie.banking import insight, offer_sweep
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


async def _demo_hh(ctx) -> Household:
    with Session(ctx.engine) as s:
        hh = demo_household(s)
    return hh or await seed(ctx)


@page_router.get("/demo", response_class=HTMLResponse)
async def demo_page() -> str:
    return (Path(__file__).parent / "static" / "demo.html").read_text()


@router.post("/buy")
async def buy(request: Request, basket: str = Query("weekly")):
    ctx = _ctx(request)
    if basket not in DATA["baskets"]:
        raise HTTPException(400, f"unknown basket; choose from {sorted(DATA['baskets'])}")
    hh = await _demo_hh(ctx)
    pid = await create_basket_purchase(ctx, hh.checking_account_id, basket)
    processed = await sync_now(ctx)  # don't wait for the 5 s loop
    return {"purchase_id": pid, "basket": basket, "processed": processed,
            "simulated": ctx.nessie.is_mock}


@router.post("/advance")
async def advance(request: Request, days: float = 0, hours: float = 0):
    ctx = _ctx(request)
    ctx.clock.advance(days=days, hours=hours)
    await sync_now(ctx)
    summary = await tick_now(ctx)
    return {"now_local": ctx.clock.local_now().isoformat(timespec="minutes"),
            "offset_hours": ctx.clock.offset.total_seconds() / 3600, **summary}


@router.post("/sweep")
async def sweep(request: Request):
    ctx = _ctx(request)
    hh = await _demo_hh(ctx)
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
async def state(request: Request, handle: str = "+15555550123"):
    ctx = _ctx(request)
    with Session(ctx.engine) as s:
        hh = demo_household(s)
        out = {
            "now_local": ctx.clock.local_now().strftime("%a %b %-d, %-I:%M %p"),
            "offset_days": round(ctx.clock.offset.total_seconds() / 86400, 2),
            "mock_nessie": ctx.nessie.is_mock, "mock_photon": ctx.photon.is_mock, "llm": ctx.llm is not None,
            "household": None,
        }
        if hh:
            fresh = list(s.exec(select(Item).where(Item.household_id == hh.id, Item.status == "fresh")
                                .order_by(Item.expires_at)))
            ins = insight(ctx, s, hh)
            out["household"] = {
                "name": hh.name, "budget": hh.weekly_budget,
                "members": [m.photon_handle + ("" if m.status == "active" else " (stopped)")
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
                out["household"]["checking_balance"] = (await ctx.nessie.get_account(hh.checking_account_id))["balance"]
                out["household"]["fund_balance"] = (await ctx.nessie.get_account(hh.grocery_fund_account_id))["balance"]
            except Exception:
                pass
    if ctx.photon.is_mock:
        out["conversation"] = ctx.photon.conversation(handle)
    return out
