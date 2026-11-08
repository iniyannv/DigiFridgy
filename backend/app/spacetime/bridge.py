"""Shared fridge: keeps this backend's inventory and the iOS app's SpacetimeDB household in sync.

The backend stores one `Item` row per unit (needed for waste, nudges and sweeps); the app stores one
FridgeItem per product with a `count`. Each app item (`external_id`) maps to a group of unit rows via
`SpaceItemLink`. Every round is a three-way merge against `SpaceSyncState`, the last agreed counts:

    new = base + (app_count - app_base) + (backend_count - base)

so "used 1 milk" over iMessage and "+1 eggs" in the app both survive. Only counts flow after an item
exists; item details (name, expiry the user set in the app) are never overwritten by the backend.

Each backend household acts as an ordinary member of an app household through its own SpacetimeDB
identity, so the server module needs no special access. A household joins in only after it opts in:
APP (or the welcome text) creates an app household, `LINK <code>` or signup with a code joins one.
"""
from __future__ import annotations

import asyncio
import hashlib
import json
import logging
import time
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from functools import lru_cache

from sqlmodel import Session, select

from ..config import BACKEND_DIR
from ..context import Ctx
from ..fridge.shelf_life import find_by_words, is_known, lookup
from ..fridge.matching import best_catalog_match
from ..models import (ApprovalLink, Household, Item, ListClaim, PendingAction, ProcessedPurchase,
                      ShoppingListItem, SpaceItemLink, SpaceListLink, SpaceSyncState, SpacetimeLink, UsageLog)
from ..photon.outbound import notify_household
from .client import is_unknown_reducer, not_applied

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


# For app items the backend catalog doesn't have: the app category's emoji and where it's kept.
APP_EMOJI = {"pantry": "🥫", "snacks": "🍫", "beverages": "🥤", "condiments": "🫙", "prepared_meals": "🍝",
             "juice": "🧃", "pickles": "🫙", "salsa": "🫙", "hummus": "🫙"}
APP_LOCATION = {"pantry": "pantry", "snacks": "pantry", "beverages": "pantry", "condiments": "pantry"}


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
        **({} if unit.source_purchase_id else {"addedBy": "imessage"}),
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


# ---------- per-process bridge memory ----------

APP_MAX_COUNT = 999             # the module's bound for an item's count
MAX_UNITS_PER_ITEM = 100        # backend unit rows the bridge will create for one app item
MAX_NEW_UNITS_PER_ROUND = 500   # ... and per household per round; the rest waits for the next round
LOG_USE_CHUNK = 1000            # log_use accepts qty 1..=1000
MISSING_REDUCER_TTL = 600.0     # seconds before retrying a reducer the published module didn't have
_MAX_MS = 4_102_444_800_000     # 2100-01-01: later (or negative) timestamps from the app are ignored


@dataclass
class _BridgeState:
    """Kept on the Ctx, so each app instance (and each test) has its own."""
    # (household, external id) -> (expected, target) of an app write whose outcome is unknown
    # (timeout after sending). The next round checks which of the two the app shows.
    pending: dict[tuple[int, str], tuple[int, int]] = field(default_factory=dict)
    # (household, reducer) -> monotonic time to try that reducer again
    missing: dict[tuple[int, str], float] = field(default_factory=dict)
    dirty: set[int] = field(default_factory=set)   # households whose app subscription fired
    full: bool = False                              # someone asked for a round of every household


def _state(ctx: Ctx) -> _BridgeState:
    st = getattr(ctx, "_spacetime_bridge", None)
    if st is None:
        st = _BridgeState()
        ctx._spacetime_bridge = st
    return st


def _reducer_missing(ctx: Ctx, household_id: int, reducer: str) -> bool:
    missing = _state(ctx).missing
    until = missing.get((household_id, reducer))
    if until is None:
        return False
    if time.monotonic() >= until:
        del missing[(household_id, reducer)]
        return False
    return True


def _mark_missing(ctx: Ctx, household_id: int, reducer: str) -> None:
    _state(ctx).missing[(household_id, reducer)] = time.monotonic() + MISSING_REDUCER_TTL


def _ms(v) -> float | None:
    """A millisecond timestamp from app JSON, or None if it's missing or nonsense."""
    if isinstance(v, bool) or not isinstance(v, (int, float)) or v != v:
        return None
    return float(v) if 0 <= v <= _MAX_MS else None


# ---------- linking ----------
#
# A backend household syncs with the app only after it opted in: APP (or the welcome text), LINK <code>,
# or signing up with an app invite code. Those create the `SpacetimeLink`; the sync never does.

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
    _reset_sync_rows(ctx, hh.id)
    await _refresh_household(ctx, link)
    log.info("household %s linked to app household %s", hh.id, link.app_household_id)
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


def _reset_sync_rows(ctx: Ctx, household_id: int) -> None:
    """Forgets the merge base for this household (it now shares a different app household)."""
    with Session(ctx.engine) as s:
        for model in (SpaceSyncState, SpaceItemLink, SpaceListLink):
            for row in s.exec(select(model).where(model.household_id == household_id)):
                s.delete(row)
        s.commit()
    pending = _state(ctx).pending
    for key in [k for k in pending if k[0] == household_id]:
        del pending[key]


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
    joins directly, so it doesn't create (and announce) an app household of its own first.

    `join_household` moves the identity out of its current app household only when the code is good,
    so a typo keeps the current link, its items and its sync state exactly as they were."""
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
            await ctx.spacetime.call(link.token, "join_household", [code])
        except Exception as e:
            # A brand-new link isn't saved: this household didn't get an app household it never asked for.
            log.warning("household %s: joining an app household failed: %s", hh.id, e)
            if "too many" in str(e).lower():
                return False, "Too many wrong codes. Wait an hour, then try the code from the app's Settings."
            return False, f"Couldn't find an app household with code {code}. Check the code in the app's Settings."
        _reset_sync_rows(ctx, hh.id)
        await _refresh_household(ctx, link)
        await sync_household(ctx, hh)
    return True, f"🔗 Linked! This fridge now shares items with the app household using code {code}."


def household_for_app(ctx: Ctx, app_household_id: str) -> Household | None:
    """The backend (bank) household that shares this app household's fridge, if any."""
    with Session(ctx.engine) as s:
        link = s.exec(select(SpacetimeLink).where(SpacetimeLink.app_household_id == app_household_id)
                      .order_by(SpacetimeLink.linked_at.desc())).first()
        return s.get(Household, link.household_id) if link else None


async def _active_link(ctx: Ctx, hh: Household) -> SpacetimeLink | None:
    with Session(ctx.engine) as s:
        link = s.get(SpacetimeLink, hh.id)
    if link is None:
        return None                       # never opted in
    if not link.app_household_id:
        link = await ensure_link(ctx, hh)  # opted in, but has no app household yet
    return link


def _note_household(ctx: Ctx, hh: Household, link: SpacetimeLink, row: dict) -> None:
    """Keeps the stored invite code current (leaving or a kick rotates it) and notices a move to
    another app household (a join whose follow-up read failed), which invalidates the merge base."""
    app_id, code = str(row.get("id") or ""), str(row.get("invite_code") or "")
    changed = False
    if app_id and app_id != link.app_household_id:
        log.warning("household %s is now in a different app household; starting a fresh sync", hh.id)
        _reset_sync_rows(ctx, hh.id)
        link.app_household_id = app_id
        changed = True
    if code and code != link.invite_code:
        link.invite_code = code
        changed = True
    if changed:
        with Session(ctx.engine) as s:
            s.merge(link)
            s.commit()


# ---------- sync ----------

def _parse_items(rows: list) -> tuple[dict[str, tuple[int, int, dict]], set[str]]:
    """my_items rows -> {id: (count clamped to the module's bound, count as sent, data)}, plus the ids
    of malformed rows. A malformed row is left out of the round entirely (not read as "deleted")."""
    app: dict[str, tuple[int, int, dict]] = {}
    bad: set[str] = set()
    for r in rows:
        ext = r.get("id") if isinstance(r, dict) else None
        if not isinstance(ext, str) or not ext or len(ext) > 64:
            log.warning("skipping an app item row without a usable id")
            continue
        try:
            raw = r["count"]
            if isinstance(raw, bool) or not isinstance(raw, int):
                raise ValueError(f"count is {type(raw).__name__}")
            data = json.loads(r["data"])
            if not isinstance(data, dict):
                raise ValueError("data is not a JSON object")
        except (KeyError, TypeError, ValueError) as e:
            log.warning("skipping malformed app item %s: %s", ext, e)
            bad.add(ext)
            continue
        app[ext] = (max(0, min(raw, APP_MAX_COUNT)), raw, data)
    return app, bad


async def sync_household(ctx: Ctx, hh: Household) -> dict:
    link = await _active_link(ctx, hh)
    if link is None:
        return {}
    st = ctx.spacetime
    rows = await st.query(link.token, "SELECT * FROM my_items")
    # Checked after reading the items: if this identity isn't a member any more (kicked, the database
    # was wiped), my_items is empty, and that must not read as "everything was used up".
    household_rows = await st.query(link.token, "SELECT * FROM my_household")
    if not household_rows:
        log.warning("household %s isn't a member of its app household any more; skipping this round", hh.id)
        return {"not_member": 1}
    _note_household(ctx, hh, link, household_rows[0])
    app, bad = _parse_items(rows)
    now = ctx.clock.now()
    stats = {"exported": 0, "imported": 0, "app_updates": 0, "backend_updates": 0, "skipped": len(bad)}
    # (reducer, args, external_id, expected app count, target app count)
    app_calls: list[tuple[str, list, str, int, int]] = []

    # Writes from earlier rounds that timed out: if the app shows the target, the write landed.
    pending = _state(ctx).pending
    landed: dict[str, int] = {}
    for key in [k for k in pending if k[0] == hh.id]:
        expected, target = pending.pop(key)
        ext = key[1]
        if ext in bad:
            continue
        current = app[ext][1] if ext in app else 0
        if current == target and current != expected:
            landed[ext] = target

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
        for ext, target in landed.items():
            if ext in states:
                states[ext].app_count = target
        # Templates for re-adding units to a group whose units are all gone.
        all_links = {}
        for l in s.exec(select(SpaceItemLink).where(SpaceItemLink.household_id == hh.id)):
            all_links.setdefault(l.external_id, l.item_id)

        budget = MAX_NEW_UNITS_PER_ROUND
        for ext in sorted(set(app) | set(groups) | set(states)):
            if ext in bad:
                continue
            units = groups.get(ext, [])
            be_count = len(units)
            app_count, sent_count, data = app.get(ext, (0, 0, None))
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
            # Never more units than the cap from the app (but never drop units the backend has).
            new = min(max(0, new), max(be_count, MAX_UNITS_PER_ITEM))
            template = units[0] if units else (s.get(Item, all_links[ext]) if ext in all_links else None)

            # Backend side
            if new < be_count:
                fresh = sorted((u for u in units if u.status == "fresh"), key=lambda u: u.expires_at)
                expired = [u for u in units if u.status == "expired"]
                if data is None:
                    # Removed in the app: expired units were thrown out (already counted as waste).
                    order = [(u, "tossed") for u in expired] + [(u, "used") for u in fresh]
                else:
                    # Count lowered in the app: someone ate it. Fresh units first, never counted as waste.
                    order = [(u, "used") for u in fresh + expired]
                for u, status in order[: be_count - new]:
                    u.status = status
                    u.status_at = now
                    s.add(u)
                stats["backend_updates"] += 1
            elif new > be_count:
                if template is None and data is None:
                    continue
                if new - be_count > budget:
                    stats["skipped"] += 1                # state untouched: next round picks it up
                    continue
                budget -= new - be_count
                for _ in range(new - be_count):
                    unit = _new_unit(ctx, hh.id, template, data, now)
                    s.add(unit)
                    s.flush()
                    s.add(SpaceItemLink(item_id=unit.id, household_id=hh.id, external_id=ext))
                stats["imported" if be_count == 0 else "backend_updates"] += 1

            # App-set expiry dates win for fresh units.
            if data is not None:
                _apply_app_expiry(ctx, s, hh.id, ext, data)

            # App side (network calls run after the local commit)
            if template is None and units:
                template = units[0]
            if data is None and new > 0 and template is not None:
                item_json = _app_item_json(ctx, ext, template, new, _store_name(s, template))
                app_calls.append(("upsert_item", [ext, new, item_json], ext, 0, new))
                stats["exported"] += 1
            elif data is not None and new != sent_count:
                app_calls.append(("set_count_if", [ext, sent_count, new], ext, sent_count, new))
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

    # Uses first: log_use needs the item to still exist in the app, and the writes below may remove it.
    stats["uses_logged"] = await push_uses(ctx, hh, link)
    for reducer, args, ext, expected, target in app_calls:
        try:
            if reducer == "set_count_if":
                await _set_app_count(ctx, hh, link, ext, expected, target)
            else:
                await st.call(link.token, reducer, args)
        except Exception as e:
            if not not_applied(e):
                pending[(hh.id, ext)] = (expected, target)   # may have landed: the next round checks
            elif "count changed" in str(e).lower():
                request_sync(ctx, hh.id)                     # edited in the app meanwhile: merge again
            log.warning("SpacetimeDB %s(%s) failed: %s", reducer, ext, e)
            continue
        with Session(ctx.engine) as s:
            row = s.exec(select(SpaceSyncState).where(SpaceSyncState.household_id == hh.id,
                                                      SpaceSyncState.external_id == ext)).first()
            if target == 0:
                if row is not None:
                    s.delete(row)
            elif row is not None:
                row.app_count = target
                s.add(row)
            s.commit()
    stats.update(await sync_list(ctx, hh, link))
    stats["approvals"] = await sync_approvals(ctx, hh, link)
    return stats


async def _set_app_count(ctx: Ctx, hh: Household, link: SpacetimeLink, ext: str, expected: int, new: int) -> None:
    """Sets the app count to `new` only if it's still `expected` (absolute, so a retry can't apply a
    change twice, and a +1 tapped meanwhile isn't overwritten)."""
    st = ctx.spacetime
    if not _reducer_missing(ctx, hh.id, "set_count_if"):
        try:
            await st.call(link.token, "set_count_if", [ext, expected, new])
            return
        except Exception as e:
            if not is_unknown_reducer(e):
                raise
            _mark_missing(ctx, hh.id, "set_count_if")
            log.info("SpacetimeDB module has no set_count_if yet; using relative writes (publish server/)")
    # Older module: relative writes, which a concurrent app edit or a retried timeout can skew.
    if new == 0:
        await st.call(link.token, "delete_item", [ext])
    else:
        await st.call(link.token, "increment_count", [ext, new - expected])


# ---------- who used what ----------
#
# USED over iMessage goes into SpacetimeDB's shared `item_use` log (reducer `log_use`), next to the
# app's −1 taps (`use_item`), so every member sees who used what and settle-up has one record.

async def push_uses(ctx: Ctx, hh: Household, link: SpacetimeLink) -> int:
    if _reducer_missing(ctx, hh.id, "log_use"):
        return 0  # the published module predates log_use: try again after the TTL
    with Session(ctx.engine) as s:
        rows = list(s.exec(select(UsageLog).where(UsageLog.household_id == hh.id, UsageLog.logged_at == None)))  # noqa: E711
        if not rows:
            return 0
        exts = {l.item_id: l.external_id for l in s.exec(
            select(SpaceItemLink).where(SpaceItemLink.item_id.in_([r.item_id for r in rows])))}
        groups: dict[str, tuple[str, list[int]]] = {}
        for r in rows:
            ext = exts.get(r.item_id)
            unit = s.get(Item, r.item_id)
            if ext is None or unit is None:
                continue  # not in the app (yet); the next round picks it up once linked
            groups.setdefault(ext, (unit.name, []))[1].append(r.id)
    sent: list[int] = []
    try:
        for ext, (name, ids) in groups.items():
            for i in range(0, len(ids), LOG_USE_CHUNK):
                chunk = ids[i:i + LOG_USE_CHUNK]
                try:
                    await ctx.spacetime.call(link.token, "log_use", [ext, len(chunk), name])
                except Exception as e:
                    if is_unknown_reducer(e):
                        _mark_missing(ctx, hh.id, "log_use")
                        log.info("SpacetimeDB module has no log_use yet; publish server/ to share iMessage uses")
                        return len(sent)
                    if not_applied(e) and "not found" in str(e).lower():
                        sent += chunk  # the item is gone from the app: nothing there to attribute it to
                        continue
                    log.warning("SpacetimeDB log_use(%s) failed: %s", ext, e)
                    break
                sent += chunk
        return len(sent)
    finally:
        if sent:
            with Session(ctx.engine) as s:
                for row in s.exec(select(UsageLog).where(UsageLog.id.in_(sent))):
                    row.logged_at = ctx.clock.now()
                    s.add(row)
                s.commit()


# ---------- shopping list ----------
#
# One list for the household: iMessage (ADD / REMOVE / ADD ALL / staple suggestions) and the app's
# Shopping list are the same entries. Each backend row maps to one app entry through `SpaceListLink`,
# whose `done` is the last agreed checked-off state. Unconfirmed staple suggestions stay here until
# someone confirms them (ADD ALL / YES). Checking an entry off in the app marks it done here; REMOVE
# over iMessage deletes it from the app; deleting it in the app removes it here.

def _list_external_id(app_household_id: str, row_id: int) -> str:
    return "list-" + hashlib.sha1(f"{app_household_id}|{row_id}".encode()).hexdigest()[:20]


def _app_list_json(ctx: Ctx, ext: str, row: ShoppingListItem, done: bool, claimed_by: str = "") -> str:
    data = {"id": ext, "name": row.name, "addedAt": _to_ms(ctx, row.added_at), "done": done}
    if claimed_by:
        data["claimedBy"] = claimed_by
    return json.dumps(data)


async def sync_list(ctx: Ctx, hh: Household, link: SpacetimeLink) -> dict:
    st = ctx.spacetime
    app: dict[str, dict] = {}
    for r in await st.query(link.token, "SELECT * FROM my_shopping"):
        try:
            entry = json.loads(r["data"])
            if isinstance(r["id"], str) and isinstance(entry, dict):
                app[r["id"]] = entry
                continue
        except (KeyError, TypeError, ValueError):
            pass
        log.warning("skipping a malformed app shopping-list row")
    stats = {"list_exported": 0, "list_imported": 0, "list_updates": 0}
    saves: list[tuple[int, str, str, bool]] = []    # (row id, ext, json, done): link is written on success
    claim_pushes: list[tuple[int, str, str, str]] = []  # (row id, ext, json, claim): synced on success
    deletes: list[tuple[int, str]] = []             # (row id, ext): link is dropped on success
    now = ctx.clock.now()

    with Session(ctx.engine) as s:
        links = {l.external_id: l for l in s.exec(select(SpaceListLink).where(SpaceListLink.household_id == hh.id))}
        linked_rows = {l.list_item_id for l in links.values()}

        for ext, l in links.items():
            row = s.get(ShoppingListItem, l.list_item_id)
            entry = app.get(ext)
            if row is None:
                if entry is not None:
                    deletes.append((l.list_item_id, ext))
                else:
                    s.delete(l)
                continue
            if entry is None:                       # deleted in the app
                if not row.done:
                    row.done = True
                    s.add(row)
                    stats["list_updates"] += 1
                s.delete(l)
                continue
            # Who's grabbing it: three-way merge against the last agreed claim (app edit wins a tie).
            app_claim = str(entry.get("claimedBy") or "")[:40]
            c = s.get(ListClaim, row.id)
            base, mine = (c.synced_name, c.name) if c else ("", "")
            if app_claim != base:
                c = c or ListClaim(list_item_id=row.id, claimed_at=now)
                c.name = c.synced_name = app_claim
                c.member_id = None if app_claim != mine else c.member_id
                s.add(c)
            elif mine != base:
                claim_pushes.append((row.id, ext, json.dumps({**entry, "claimedBy": mine or None}), mine))
            app_done = bool(entry.get("done"))
            if app_done != l.done:                  # checked / unchecked in the app (wins a tie)
                row.done = l.done = app_done
                s.add(row)
                s.add(l)
                stats["list_updates"] += 1
            elif row.done != l.done:                # changed here (REMOVE over iMessage)
                deletes.append((row.id, ext))
                stats["list_updates"] += 1

        # Added in the app: becomes a row here, or pairs with the same open item added over iMessage.
        open_unlinked = {}
        for r in s.exec(select(ShoppingListItem).where(ShoppingListItem.household_id == hh.id,
                                                       ShoppingListItem.done == False)  # noqa: E712
                        .order_by(ShoppingListItem.added_at)):
            if r.id not in linked_rows:
                open_unlinked.setdefault(r.name.lower(), r)
        for ext, entry in app.items():
            if ext in links:
                continue
            name = entry.get("name")
            name = name.strip()[:60] if isinstance(name, str) else ""
            if not name:
                continue
            done = bool(entry.get("done"))
            row = open_unlinked.pop(name.lower(), None)
            if row is None:
                info = best_catalog_match(name)
                added_ms = _ms(entry.get("addedAt"))
                added = _from_ms(ctx, added_ms) if added_ms else now
                row = ShoppingListItem(household_id=hh.id, name=name, sku=info.sku if info else None,
                                       source="app", confirmed=True, added_at=added, done=done)
                stats["list_imported"] += 1
            else:
                row.confirmed = True
                row.done = done
            s.add(row)
            s.flush()
            s.add(SpaceListLink(list_item_id=row.id, household_id=hh.id, external_id=ext, done=done))
            app_claim = str(entry.get("claimedBy") or "")[:40]
            if app_claim:
                s.merge(ListClaim(list_item_id=row.id, name=app_claim, synced_name=app_claim, claimed_at=now))

        # Added here (confirmed and still open): goes to the app.
        for row in open_unlinked.values():
            if row.confirmed:
                ext = _list_external_id(link.app_household_id, row.id)
                c = s.get(ListClaim, row.id)
                saves.append((row.id, ext, _app_list_json(ctx, ext, row, False, c.name if c else ""), False))
        s.commit()

    for row_id, ext in deletes:
        try:
            await st.call(link.token, "delete_shopping_item", [ext])
        except Exception as e:
            log.warning("SpacetimeDB delete_shopping_item(%s) failed: %s", ext, e)
            continue
        with Session(ctx.engine) as s:
            l = s.exec(select(SpaceListLink).where(SpaceListLink.household_id == hh.id,
                                                   SpaceListLink.external_id == ext)).first()
            if l is not None:
                s.delete(l)
                s.commit()
    for row_id, ext, data, done in saves:
        try:
            await st.call(link.token, "save_shopping_item", [ext, data])
        except Exception as e:
            log.warning("SpacetimeDB save_shopping_item(%s) failed: %s", ext, e)
            continue
        with Session(ctx.engine) as s:
            s.merge(SpaceListLink(list_item_id=row_id, household_id=hh.id, external_id=ext, done=done))
            c = s.get(ListClaim, row_id)
            if c:
                c.synced_name = c.name
                s.add(c)
            s.commit()
        stats["list_exported"] += 1
    for row_id, ext, data, claim in claim_pushes:
        try:
            await st.call(link.token, "save_shopping_item", [ext, data])
        except Exception as e:
            log.warning("SpacetimeDB claim update (%s) failed: %s", ext, e)
            continue
        with Session(ctx.engine) as s:
            c = s.get(ListClaim, row_id)
            if c:
                c.synced_name = claim
                s.add(c)
                s.commit()
        stats["list_updates"] += 1
    return stats


# ---------- approvals: answer in iMessage or in the app ----------

_approvals_missing = False  # the published module predates `my_approvals`


async def sync_approvals(ctx: Ctx, hh: Household, link: SpacetimeLink) -> int:
    """Posts each open YES/NO question to SpacetimeDB, acts on answers given in the app, and closes
    questions that were answered by text or expired."""
    global _approvals_missing
    from ..brain import approvals, pending
    from ..photon.outbound import key_salt, notify_group, notify_household
    if _approvals_missing:
        return 0
    st = ctx.spacetime
    try:
        rows = {r["id"]: r for r in await st.query(link.token, "SELECT * FROM my_approvals")}
    except Exception as e:
        if "my_approvals" in str(e) or "no such" in str(e).lower():
            _approvals_missing = True
            log.info("SpacetimeDB module has no approvals yet; publish server/ to answer questions in the app")
            return 0
        raise
    now = ctx.clock.now()
    changed = 0
    with Session(ctx.engine) as s:
        links = {l.action_id: l.approval_id for l in s.exec(select(ApprovalLink).where(ApprovalLink.household_id == hh.id))}
        open_ids = {a.id for a in s.exec(select(PendingAction).where(
            PendingAction.household_id == hh.id, PendingAction.status == "open",
            PendingAction.kind.in_(pending.YES_NO_KINDS), PendingAction.expires_at > now))}

    async def close(action_id: int, approval_id: str) -> None:
        try:
            await st.call(link.token, "close_approval", [approval_id])
        except Exception as e:
            log.warning("close_approval(%s) failed: %s", approval_id, e)
            return
        with Session(ctx.engine) as s:
            row = s.get(ApprovalLink, action_id)
            if row:
                s.delete(row)
                s.commit()

    for action_id, approval_id in links.items():
        row = rows.get(approval_id)
        if action_id not in open_ids:          # answered by text, or expired
            await close(action_id, approval_id)
            changed += 1
        elif row and row["status"] in ("approved", "declined"):
            ok, message = await approvals.apply_decision(ctx, hh, action_id, row["status"] == "approved",
                                                         row.get("decided_by_hex") or "")
            await close(action_id, approval_id)  # a refused money answer is re-posted below as open
            if message:
                key = f"approval:{approval_id}:{row['status']}"
                await notify_household(ctx, hh.id, message, key)
                await notify_group(ctx, hh.id, message, key)
            changed += 1
            if ok:
                open_ids.discard(action_id)

    with Session(ctx.engine) as s:
        posted = {l.action_id for l in s.exec(select(ApprovalLink).where(ApprovalLink.household_id == hh.id))}
        todo = [s.get(PendingAction, i) for i in open_ids - posted]
        todo = [(a.id, a.kind, *approvals.describe(s, hh, a)) for a in todo if a and a.status == "open"]
    for action_id, kind, title, detail, money in todo:
        approval_id = f"q-{key_salt(ctx)}-{hh.id}-{action_id}"
        try:
            await st.call(link.token, "post_approval", [approval_id, kind, title, detail[:2000], money])
        except Exception as e:
            log.warning("post_approval(%s) failed: %s", approval_id, e)
            continue
        with Session(ctx.engine) as s:
            s.merge(ApprovalLink(action_id=action_id, household_id=hh.id, approval_id=approval_id))
            s.commit()
        changed += 1
    return changed


def _new_unit(ctx: Ctx, household_id: int, template: Item | None, data: dict | None, now: datetime) -> Item:
    if data is not None and (template is None or template.source_purchase_id is None):
        name = data.get("name")
        name = name.strip()[:80] if isinstance(name, str) and name.strip() else "item"
        info = find_by_words(name) or lookup(name.lower().replace(" ", "_"))
        emoji, location = info.emoji, info.location
        app_cat = data.get("category") if isinstance(data.get("category"), str) else None
        if app_cat and app_cat != "other" and is_known(info.sku) and app_category(info.display_name) != app_cat:
            # The app (and its AI) chose the category; a word match on the name ("Cup Noodles Chicken
            # Flavor" -> chicken breast) would put it in the wrong place with the wrong emoji.
            info = lookup(name.lower().replace(" ", "_"))
            emoji, location = APP_EMOJI.get(app_cat, info.emoji), APP_LOCATION.get(app_cat, info.location)
        expires_ms, added_ms = _ms(data.get("expiresAt")), _ms(data.get("addedAt"))
        expires = _from_ms(ctx, expires_ms) if expires_ms else now + timedelta(days=info.shelf_life_days)
        added = _from_ms(ctx, added_ms) if added_ms else now
        return Item(household_id=household_id, sku=info.sku, name=name.lower(), category=info.category,
                    location=location, emoji=emoji, price=0.0, purchased_at=added, expires_at=expires,
                    status="fresh" if expires > now else "expired")
    t = template
    return Item(household_id=household_id, sku=t.sku, name=t.name, category=t.category, location=t.location,
                emoji=t.emoji, price=t.price, purchased_at=t.purchased_at,
                expires_at=max(t.expires_at, now + timedelta(days=1)), status="fresh",
                source_purchase_id=t.source_purchase_id)


def _apply_app_expiry(ctx: Ctx, s: Session, household_id: int, ext: str, data: dict) -> None:
    expires_ms = _ms(data.get("expiresAt"))
    if data.get("expiryIsEstimated", True) or not expires_ms:
        return
    expires = _from_ms(ctx, expires_ms)
    ids = [l.item_id for l in s.exec(select(SpaceItemLink).where(SpaceItemLink.household_id == household_id,
                                                                  SpaceItemLink.external_id == ext))]
    for unit in s.exec(select(Item).where(Item.id.in_(ids), Item.status == "fresh")):
        if abs((unit.expires_at - expires).total_seconds()) > 3600:
            unit.expires_at = expires
            s.add(unit)


async def sync_all(ctx: Ctx, only: set[int] | None = None) -> dict:
    """Syncs every opted-in household (one with a `SpacetimeLink`), or just those in `only`."""
    if ctx.spacetime is None:
        return {}
    with Session(ctx.engine) as s:
        ids = sorted(l.household_id for l in s.exec(select(SpacetimeLink)))
        if only is not None:
            ids = [i for i in ids if i in only]
        households = [hh for hh in (s.get(Household, i) for i in ids) if hh is not None]
    totals: dict = {}
    for hh in households:
        try:
            for k, v in (await sync_household(ctx, hh)).items():
                totals[k] = totals.get(k, 0) + v
        except Exception:
            log.exception("SpacetimeDB sync failed for household %s", hh.id)
    return totals


_lock = asyncio.Lock()


async def sync_now(ctx: Ctx, only: set[int] | None = None) -> dict:
    async with _lock:
        return await sync_all(ctx, only)


def request_sync(ctx: Ctx, household_id: int | None = None) -> None:
    """Runs a sync round now instead of at the next interval (after an iMessage command, or when the
    app changed the fridge or the list). With `household_id`, only that household is synced."""
    st = _state(ctx)
    if household_id is None:
        st.full = True
    else:
        st.dirty.add(household_id)
    if ctx.spacetime_wake is not None:
        ctx.spacetime_wake.set()


async def sync_loop(ctx: Ctx) -> None:
    """Syncs whenever something changes (see `request_sync` and `watch_loop`), and on a timer as a fallback."""
    wake = ctx.spacetime_wake = asyncio.Event()
    st = _state(ctx)
    full = True
    while True:
        if full:
            st.dirty.clear()
            only = None
        else:
            only, st.dirty = st.dirty, set()
        try:
            await sync_now(ctx, only)
        except Exception:
            log.exception("SpacetimeDB sync loop error")
        try:
            await asyncio.wait_for(wake.wait(), timeout=ctx.settings.spacetime_interval)
            await asyncio.sleep(0.15)  # one round for a burst of changes
            full = st.full
        except asyncio.TimeoutError:
            full = True
        st.full = False
        wake.clear()


async def watch_loop(ctx: Ctx) -> None:
    """One live SpacetimeDB subscription per linked household: an app change wakes the sync loop for
    that household within a fraction of a second instead of waiting for the next poll."""
    st = ctx.spacetime
    if st is None or st.is_mock:
        return
    watchers: dict[int, tuple[str, asyncio.Task]] = {}
    try:
        while True:
            queries = ["SELECT * FROM my_items", "SELECT * FROM my_shopping"] \
                + ([] if _approvals_missing else ["SELECT * FROM my_approvals"])
            with Session(ctx.engine) as s:
                # Key on the queries too: an older module without my_approvals restarts the watch without it.
                wanted = {l.household_id: f"{l.token}|{len(queries)}" for l in s.exec(select(SpacetimeLink))
                          if l.app_household_id}
            for hid, (key, task) in list(watchers.items()):
                if wanted.get(hid) != key or task.done():
                    task.cancel()
                    del watchers[hid]
            for hid, key in wanted.items():
                if hid not in watchers:
                    task = asyncio.create_task(
                        st.watch(key.rsplit("|", 1)[0], queries, lambda hid=hid: request_sync(ctx, hid)),
                        name=f"spacetime-watch-{hid}")
                    watchers[hid] = (key, task)
            await asyncio.sleep(5)
    finally:
        for _, task in watchers.values():
            task.cancel()
