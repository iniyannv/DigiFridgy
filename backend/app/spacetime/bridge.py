"""Shared fridge: keeps this backend's inventory and the iOS app's SpacetimeDB household in sync.

The backend stores one `Item` row per unit (needed for waste, nudges and sweeps); the app stores one
FridgeItem per product with a `count`. Each app item (`external_id`) maps to a group of unit rows via
`SpaceItemLink`. Every round is a three-way merge against `SpaceSyncState`, the last agreed counts:

    new = base + (app_count - app_base) + (backend_count - base)

so "used 1 milk" over iMessage and "+1 eggs" in the app both survive. Only counts flow after an item
exists; item details (name, expiry the user set in the app) are never overwritten by the backend.

Each backend household acts as an ordinary member of an app household through its own SpacetimeDB
identity, so the server module needs no special access. It creates an app household on first sync
(members get the invite code to join from the app), or joins an existing one with `LINK <code>`.
"""
from __future__ import annotations

import asyncio
import hashlib
import json
import logging
import uuid
from datetime import datetime, timedelta, timezone
from functools import lru_cache

from sqlmodel import Session, select

from ..config import BACKEND_DIR
from ..context import Ctx
from ..fridge.shelf_life import find_by_words, lookup
from ..models import Household, Item, ProcessedPurchase, SpaceItemLink, SpaceSyncState, SpacetimeLink
from ..photon.outbound import notify_household

log = logging.getLogger("spacetime")

PRESENT = ("fresh", "expired")  # still physically in the fridge
APP_SHELF_LIFE = BACKEND_DIR.parent / "DigiFridgy" / "Resources" / "shelf_life.json"


# ---------- app category mapping (mirrors the app's ShelfLifeService keyword match) ----------

@lru_cache
def _app_categories() -> list[tuple[str, list[list[str]]]]:
    try:
        data = json.loads(APP_SHELF_LIFE.read_text())
    except (OSError, ValueError):
        return []
    return [(c["id"], [_tokens(k) for k in c["keywords"]]) for c in data["categories"]]


def _tokens(text: str) -> list[str]:
    out, cur = [], ""
    for ch in text.lower():
        if ch.isalnum() or ch == "%":
            cur += ch
        elif cur:
            out.append(cur)
            cur = ""
    if cur:
        out.append(cur)
    return out


def _word_matches(token: str, kw: str) -> bool:
    return token in (kw, kw + "s", kw + "es") or (kw.endswith("y") and token == kw[:-1] + "ies")


def app_category(name: str) -> str:
    """Longest keyword wins; ties go to the match nearest the end (head noun)."""
    tokens = _tokens(name)
    best = None
    for cid, keywords in _app_categories():
        for kw in keywords:
            if not kw or len(kw) > len(tokens):
                continue
            for start in range(len(tokens) - len(kw) + 1):
                if all(_word_matches(tokens[start + i], kw[i]) for i in range(len(kw))):
                    score = (len(kw), start + len(kw))
                    if best is None or score > best[0]:
                        best = (score, cid)
    return best[1] if best else "other"


_IMPLIED_ALLERGENS = {
    **dict.fromkeys(["milk", "cream", "butter", "yogurt", "sour_cream", "cottage_cheese", "cream_cheese",
                     "hard_cheese", "soft_cheese", "shredded_cheese", "ice_cream"], ["milk"]),
    "eggs": ["eggs"], "bread": ["wheat"], "tortillas": ["wheat"], "dough": ["wheat"], "fresh_pasta": ["wheat"],
    "pizza": ["wheat"], "fish": ["fish"], "smoked_fish": ["fish"], "shellfish": ["shellfish"],
    "tofu": ["soy"], "plant_milk": ["soy"], "hummus": ["sesame"],
}


# ---------- time conversion (backend may run on a demo time-skip) ----------

def _to_ms(ctx: Ctx, dt: datetime) -> int:
    real = dt - ctx.clock.offset
    return int(real.replace(tzinfo=timezone.utc).timestamp() * 1000)


def _from_ms(ctx: Ctx, ms: float) -> datetime:
    return datetime.fromtimestamp(ms / 1000, tz=timezone.utc).replace(tzinfo=None) + ctx.clock.offset


def _app_item_json(ctx: Ctx, external_id: str, unit: Item, count: int, store: str | None = None) -> str:
    category = app_category(unit.name)
    name = unit.name[:1].upper() + unit.name[1:]
    data = {
        "id": external_id, "name": name, "category": category, "count": count,
        "addedAt": _to_ms(ctx, unit.purchased_at), "addedBy": BANK_ADDED_BY,
        "expiresAt": _to_ms(ctx, unit.expires_at), "expiryIsEstimated": True,
        # "receipt" so app builds without a "bank" source still decode it; addedBy marks card purchases.
        "source": "receipt", "allergens": _IMPLIED_ALLERGENS.get(category, []),
    }
    if unit.source_purchase_id:
        data["price"] = round(unit.price, 2)
        if store:
            data["store"] = store
    return json.dumps(data)


BANK_ADDED_BY = "bank-purchase"


def _store_name(s: Session, unit: Item) -> str | None:
    if not unit.source_purchase_id:
        return None
    p = s.get(ProcessedPurchase, unit.source_purchase_id)
    return (p.merchant_name or None) if p else None


def _external_id(app_household_id: str, unit: Item) -> str:
    """Stable per app household, so relinking to another household gets fresh ids."""
    basis = unit.source_purchase_id or f"{unit.expires_at:%Y%m%d}"
    digest = hashlib.sha1(f"{app_household_id}|{basis}|{unit.sku}".encode()).hexdigest()[:20]
    return f"bank-{digest}"


# ---------- linking ----------

async def ensure_link(ctx: Ctx, hh: Household, announce: bool = True) -> SpacetimeLink:
    with Session(ctx.engine) as s:
        link = s.get(SpacetimeLink, hh.id)
    if link and link.app_household_id:
        return link
    st = ctx.spacetime
    if link is None:
        identity, token = await st.create_identity()
        link = SpacetimeLink(household_id=hh.id, identity=identity, token=token, linked_at=ctx.clock.real_now())
    await st.call(link.token, "create_household", [str(uuid.uuid4()), hh.name or "Our Fridge"])
    await _refresh_household(ctx, link)
    log.info("household %s linked to app household %s (code %s)", hh.id, link.app_household_id, link.invite_code)
    if announce:
        await notify_household(ctx, hh.id, app_invite_text(link.invite_code), f"app-link:{link.app_household_id}")
    return link


async def _refresh_household(ctx: Ctx, link: SpacetimeLink) -> None:
    rows = await ctx.spacetime.query(link.token, "SELECT * FROM my_household")
    if not rows:
        raise RuntimeError("SpacetimeDB household not visible after create/join")
    link.app_household_id = rows[0]["id"]
    link.invite_code = rows[0]["invite_code"]
    with Session(ctx.engine) as s:
        s.merge(link)
        s.commit()


def app_invite_text(code: str) -> str:
    return (f"📱 This fridge is also in the DigiFridgy app. Open it, tap Join, and enter {code}. "
            "Changes in the app and here stay in sync.")


def invite_code(ctx: Ctx, household_id: int) -> str | None:
    with Session(ctx.engine) as s:
        link = s.get(SpacetimeLink, household_id)
        return link.invite_code if link and link.invite_code else None


async def link_to_code(ctx: Ctx, hh: Household, code: str) -> str:
    """Moves this backend household into an existing app household (from the app's invite code)."""
    return (await join_app_household(ctx, hh, code))[1]


async def join_app_household(ctx: Ctx, hh: Household, code: str) -> tuple[bool, str]:
    """Like `link_to_code`, but also says whether it worked. A household that was never linked
    joins directly, so it doesn't create (and announce) an app household of its own first."""
    if ctx.spacetime is None:
        return False, "The app connection isn't set up on this server."
    code = code.strip().upper()
    async with _lock:
        with Session(ctx.engine) as s:
            link = s.get(SpacetimeLink, hh.id)
        if link is None:
            identity, token = await ctx.spacetime.create_identity()
            link = SpacetimeLink(household_id=hh.id, identity=identity, token=token,
                                 linked_at=ctx.clock.real_now())
        elif link.app_household_id and code == link.invite_code:
            return True, f"Already linked to that app household ({code})."
        try:
            if link.app_household_id:
                await ctx.spacetime.call(link.token, "leave_household", [])
            await ctx.spacetime.call(link.token, "join_household", [code])
        except Exception as e:
            # Joining failed: the next sync gives this household an app household of its own.
            log.warning("link to %s failed: %s", code, e)
            link.app_household_id = ""
            with Session(ctx.engine) as s:
                s.merge(link)
                s.commit()
            return False, f"Couldn't find an app household with code {code}. Check the code in the app's Settings."
        with Session(ctx.engine) as s:
            for row in s.exec(select(SpaceSyncState).where(SpaceSyncState.household_id == hh.id)):
                s.delete(row)
            for row in s.exec(select(SpaceItemLink).where(SpaceItemLink.household_id == hh.id)):
                s.delete(row)
            s.commit()
        await _refresh_household(ctx, link)
        await sync_household(ctx, hh)
    return True, f"🔗 Linked! This fridge now shares items with the app household using code {code}."


def household_for_app(ctx: Ctx, app_household_id: str) -> Household | None:
    """The backend (bank) household that shares this app household's fridge, if any."""
    with Session(ctx.engine) as s:
        link = s.exec(select(SpacetimeLink).where(SpacetimeLink.app_household_id == app_household_id)
                      .order_by(SpacetimeLink.linked_at.desc())).first()
        return s.get(Household, link.household_id) if link else None


# ---------- sync ----------

async def sync_household(ctx: Ctx, hh: Household) -> dict:
    st = ctx.spacetime
    link = await ensure_link(ctx, hh)
    rows = await st.query(link.token, "SELECT * FROM my_items")
    app = {r["id"]: (int(r["count"]), r["data"]) for r in rows}
    now = ctx.clock.now()
    stats = {"exported": 0, "imported": 0, "app_updates": 0, "backend_updates": 0}
    app_calls: list[tuple[str, list, str, int]] = []  # (reducer, args, external_id, target)

    with Session(ctx.engine) as s:
        present = list(s.exec(select(Item).where(Item.household_id == hh.id, Item.status.in_(PRESENT))))
        links = {l.item_id: l.external_id for l in s.exec(
            select(SpaceItemLink).where(SpaceItemLink.household_id == hh.id))}
        groups: dict[str, list[Item]] = {}
        for unit in present:
            ext = links.get(unit.id)
            if ext is None:
                ext = _external_id(link.app_household_id, unit)
                s.add(SpaceItemLink(item_id=unit.id, household_id=hh.id, external_id=ext))
            groups.setdefault(ext, []).append(unit)
        states = {r.external_id: r for r in s.exec(
            select(SpaceSyncState).where(SpaceSyncState.household_id == hh.id))}
        # Templates for re-adding units to a group whose units are all gone.
        all_links = {}
        for l in s.exec(select(SpaceItemLink).where(SpaceItemLink.household_id == hh.id)):
            all_links.setdefault(l.external_id, l.item_id)

        for ext in set(app) | set(groups) | set(states):
            units = groups.get(ext, [])
            be_count = len(units)
            app_count, data = app.get(ext, (0, None))
            state = states.get(ext)
            if state is None:
                if data is not None and be_count == 0:
                    new = app_count                      # added in the app
                elif data is None:
                    new = be_count                       # added by a bank purchase
                else:
                    new = max(app_count, be_count)       # both exist, no history (e.g. crash mid-sync)
            else:
                new = state.count + (app_count - state.app_count) + (be_count - state.count)
            new = max(0, new)

            # Backend side
            if new < be_count:
                expired = [u for u in units if u.status == "expired"]
                fresh = sorted((u for u in units if u.status == "fresh"), key=lambda u: u.expires_at)
                for u in (expired + fresh)[: be_count - new]:
                    # Expired units were already counted as waste; removing them in the app = tossed.
                    u.status = "tossed" if u.status == "expired" else "used"
                    u.status_at = now
                    s.add(u)
                stats["backend_updates"] += 1
            elif new > be_count:
                template = units[0] if units else (s.get(Item, all_links[ext]) if ext in all_links else None)
                if template is None and data is None:
                    continue
                for _ in range(new - be_count):
                    unit = _new_unit(ctx, hh.id, template, data, now)
                    s.add(unit)
                    s.flush()
                    s.add(SpaceItemLink(item_id=unit.id, household_id=hh.id, external_id=ext))
                stats["imported" if be_count == 0 else "backend_updates"] += 1

            # App-set expiry dates win for fresh units.
            if data is not None:
                _apply_app_expiry(ctx, s, ext, data)

            # App side (network calls run after the local commit)
            template = units[0] if units else (s.get(Item, all_links[ext]) if ext in all_links else None)
            if data is None and new > 0 and template is not None:
                item_json = _app_item_json(ctx, ext, template, new, _store_name(s, template))
                app_calls.append(("upsert_item", [ext, new, item_json], ext, new))
                stats["exported"] += 1
            elif data is not None and new != app_count:
                if new == 0:
                    app_calls.append(("delete_item", [ext], ext, 0))
                else:
                    app_calls.append(("increment_count", [ext, new - app_count], ext, new))
                stats["app_updates"] += 1

            row = state or SpaceSyncState(external_id=ext, household_id=hh.id)
            row.count = new
            row.app_count = app_count if data is not None else 0  # confirmed below on success
            if new == 0 and data is None:
                if state is not None:
                    s.delete(state)
            else:
                s.add(row)
        s.commit()

    for reducer, args, ext, target in app_calls:
        try:
            await st.call(link.token, reducer, args)
        except Exception as e:
            log.warning("SpacetimeDB %s(%s) failed: %s", reducer, ext, e)
            continue
        with Session(ctx.engine) as s:
            row = s.get(SpaceSyncState, ext)
            if target == 0:
                if row is not None:
                    s.delete(row)
            elif row is not None:
                row.app_count = target
                s.add(row)
            s.commit()
    return stats


def _new_unit(ctx: Ctx, household_id: int, template: Item | None, data: str | None, now: datetime) -> Item:
    if data is not None and (template is None or template.source_purchase_id is None):
        app = json.loads(data)
        name = app.get("name") or "item"
        info = find_by_words(name) or lookup(name.lower().replace(" ", "_"))
        expires = _from_ms(ctx, app["expiresAt"]) if app.get("expiresAt") else now + timedelta(days=info.shelf_life_days)
        added = _from_ms(ctx, app["addedAt"]) if app.get("addedAt") else now
        return Item(household_id=household_id, sku=info.sku, name=name.lower(), category=info.category,
                    location=info.location, emoji=info.emoji, price=0.0, purchased_at=added, expires_at=expires,
                    status="fresh" if expires > now else "expired")
    t = template
    return Item(household_id=household_id, sku=t.sku, name=t.name, category=t.category, location=t.location,
                emoji=t.emoji, price=t.price, purchased_at=t.purchased_at,
                expires_at=max(t.expires_at, now + timedelta(days=1)), status="fresh",
                source_purchase_id=t.source_purchase_id)


def _apply_app_expiry(ctx: Ctx, s: Session, ext: str, data: str) -> None:
    app = json.loads(data)
    if app.get("expiryIsEstimated", True) or not app.get("expiresAt"):
        return
    expires = _from_ms(ctx, app["expiresAt"])
    ids = [l.item_id for l in s.exec(select(SpaceItemLink).where(SpaceItemLink.external_id == ext))]
    for unit in s.exec(select(Item).where(Item.id.in_(ids), Item.status == "fresh")):
        if abs((unit.expires_at - expires).total_seconds()) > 3600:
            unit.expires_at = expires
            s.add(unit)


async def sync_all(ctx: Ctx) -> dict:
    if ctx.spacetime is None:
        return {}
    with Session(ctx.engine) as s:
        households = list(s.exec(select(Household)))
    totals: dict = {}
    for hh in households:
        try:
            for k, v in (await sync_household(ctx, hh)).items():
                totals[k] = totals.get(k, 0) + v
        except Exception:
            log.exception("SpacetimeDB sync failed for household %s", hh.id)
    return totals


_lock = asyncio.Lock()


async def sync_now(ctx: Ctx) -> dict:
    async with _lock:
        return await sync_all(ctx)


async def sync_loop(ctx: Ctx) -> None:
    while True:
        try:
            await sync_now(ctx)
        except Exception:
            log.exception("SpacetimeDB sync loop error")
        await asyncio.sleep(ctx.settings.spacetime_interval)
