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
from ..fridge.matching import best_catalog_match
from ..models import (Household, Item, ProcessedPurchase, ShoppingListItem, SpaceItemLink, SpaceListLink,
                      SpaceSyncState, SpacetimeLink, UsageLog)
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
            for row in s.exec(select(SpaceListLink).where(SpaceListLink.household_id == hh.id)):
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
                _apply_app_expiry(ctx, s, hh.id, ext, data)

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
    stats["uses_logged"] = await push_uses(ctx, hh, link)
    return stats


# ---------- who used what ----------
#
# USED over iMessage goes into SpacetimeDB's shared `item_use` log (reducer `log_use`), next to the
# app's −1 taps (`use_item`), so every member sees who used what and settle-up has one record.

_log_use_missing = False  # the published module predates `log_use`: don't retry every round


async def push_uses(ctx: Ctx, hh: Household, link: SpacetimeLink) -> int:
    global _log_use_missing
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
    if _log_use_missing:
        sent = [i for _, ids in groups.values() for i in ids]
    else:
        sent = []
        for ext, (name, ids) in groups.items():
            try:
                await ctx.spacetime.call(link.token, "log_use", [ext, len(ids), name])
                sent += ids
            except Exception as e:
                if "log_use" in str(e) or "No such reducer" in str(e) or "404" in str(e):
                    _log_use_missing = True
                    log.info("SpacetimeDB module has no log_use yet; publish server/ to share iMessage uses")
                    sent = [i for _, i2 in groups.values() for i in i2]
                    break
                log.warning("SpacetimeDB log_use(%s) failed: %s", ext, e)
    if sent:
        with Session(ctx.engine) as s:
            for row in s.exec(select(UsageLog).where(UsageLog.id.in_(sent))):
                row.logged_at = ctx.clock.now()
                s.add(row)
            s.commit()
    return len(sent)


# ---------- shopping list ----------
#
# One list for the household: iMessage (ADD / REMOVE / ADD ALL / staple suggestions) and the app's
# Shopping list are the same entries. Each backend row maps to one app entry through `SpaceListLink`,
# whose `done` is the last agreed checked-off state. Unconfirmed staple suggestions stay here until
# someone confirms them (ADD ALL / YES). Checking an entry off in the app marks it done here; REMOVE
# over iMessage deletes it from the app; deleting it in the app removes it here.

def _list_external_id(app_household_id: str, row_id: int) -> str:
    return "list-" + hashlib.sha1(f"{app_household_id}|{row_id}".encode()).hexdigest()[:20]


def _app_list_json(ctx: Ctx, ext: str, row: ShoppingListItem, done: bool) -> str:
    return json.dumps({"id": ext, "name": row.name, "addedAt": _to_ms(ctx, row.added_at), "done": done})


async def sync_list(ctx: Ctx, hh: Household, link: SpacetimeLink) -> dict:
    st = ctx.spacetime
    app: dict[str, dict] = {}
    for r in await st.query(link.token, "SELECT * FROM my_shopping"):
        try:
            app[r["id"]] = json.loads(r["data"])
        except (TypeError, ValueError):
            continue
    stats = {"list_exported": 0, "list_imported": 0, "list_updates": 0}
    saves: list[tuple[int, str, str, bool]] = []    # (row id, ext, json, done): link is written on success
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
            name = str(entry.get("name") or "").strip()[:60]
            if not name:
                continue
            done = bool(entry.get("done"))
            row = open_unlinked.pop(name.lower(), None)
            if row is None:
                info = best_catalog_match(name)
                added = _from_ms(ctx, entry["addedAt"]) if entry.get("addedAt") else now
                row = ShoppingListItem(household_id=hh.id, name=name, sku=info.sku if info else None,
                                       source="app", confirmed=True, added_at=added, done=done)
                stats["list_imported"] += 1
            else:
                row.confirmed = True
                row.done = done
            s.add(row)
            s.flush()
            s.add(SpaceListLink(list_item_id=row.id, household_id=hh.id, external_id=ext, done=done))

        # Added here (confirmed and still open): goes to the app.
        for row in open_unlinked.values():
            if row.confirmed:
                ext = _list_external_id(link.app_household_id, row.id)
                saves.append((row.id, ext, _app_list_json(ctx, ext, row, False), False))
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
            s.commit()
        stats["list_exported"] += 1
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


def _apply_app_expiry(ctx: Ctx, s: Session, household_id: int, ext: str, data: str) -> None:
    app = json.loads(data)
    if app.get("expiryIsEstimated", True) or not app.get("expiresAt"):
        return
    expires = _from_ms(ctx, app["expiresAt"])
    ids = [l.item_id for l in s.exec(select(SpaceItemLink).where(SpaceItemLink.household_id == household_id,
                                                                  SpaceItemLink.external_id == ext))]
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


def request_sync(ctx: Ctx) -> None:
    """Runs a sync round now instead of at the next interval (after an iMessage command, or when the
    app changed the fridge or the list)."""
    if ctx.spacetime_wake is not None:
        ctx.spacetime_wake.set()


async def sync_loop(ctx: Ctx) -> None:
    """Syncs whenever something changes (see `request_sync` and `watch_loop`), and on a timer as a fallback."""
    wake = ctx.spacetime_wake = asyncio.Event()
    while True:
        try:
            await sync_now(ctx)
        except Exception:
            log.exception("SpacetimeDB sync loop error")
        try:
            await asyncio.wait_for(wake.wait(), timeout=ctx.settings.spacetime_interval)
            await asyncio.sleep(0.15)  # one round for a burst of changes
        except asyncio.TimeoutError:
            pass
        wake.clear()


async def watch_loop(ctx: Ctx) -> None:
    """One live SpacetimeDB subscription per linked household: an app change wakes the sync loop
    within a fraction of a second instead of waiting for the next poll."""
    st = ctx.spacetime
    if st is None or st.is_mock:
        return
    watchers: dict[int, tuple[str, asyncio.Task]] = {}
    try:
        while True:
            with Session(ctx.engine) as s:
                wanted = {l.household_id: l.token for l in s.exec(select(SpacetimeLink))
                          if l.app_household_id}
            for hid, (token, task) in list(watchers.items()):
                if wanted.get(hid) != token or task.done():
                    task.cancel()
                    del watchers[hid]
            for hid, token in wanted.items():
                if hid not in watchers:
                    task = asyncio.create_task(
                        st.watch(token, ["SELECT * FROM my_items", "SELECT * FROM my_shopping"],
                                 lambda: request_sync(ctx)),
                        name=f"spacetime-watch-{hid}")
                    watchers[hid] = (token, task)
            await asyncio.sleep(5)
    finally:
        for _, task in watchers.values():
            task.cancel()
