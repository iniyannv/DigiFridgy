"""Minimal SpacetimeDB 2.x HTTP client for the shared fridge (module: ../server/spacetimedb).

Same API the iOS app uses:
- `POST /v1/identity` → a new identity + token (one per backend household)
- `POST /v1/database/:db/call/:reducer` with a JSON array of args, `Authorization: Bearer <token>`
- `POST /v1/database/:db/sql` with one SQL statement, against the per-caller views (`my_items`, …)
- `GET /v1/database/:db/subscribe` (WebSocket, subprotocol `v1.json.spacetimedb`): a live subscription
  to the views, so the bridge syncs as soon as someone changes the fridge in the app

Reducer errors (`Err(String)`) come back as HTTP 530 with the message as the body.
"""
from __future__ import annotations

import asyncio
import json
import logging
import ssl
import uuid
from dataclasses import dataclass, field
from typing import Awaitable, Callable

import certifi
import httpx
import websockets

log = logging.getLogger("spacetime")


class SpacetimeError(Exception):
    pass


class SpacetimeClient:
    is_mock = False

    def __init__(self, host: str, database: str):
        scheme = "http" if host.startswith(("localhost", "127.")) else "https"
        self.base = f"{scheme}://{host}"
        self.database = database
        self._http = httpx.AsyncClient(timeout=20)

    async def close(self) -> None:
        await self._http.aclose()

    async def create_identity(self) -> tuple[str, str]:
        r = await self._http.post(f"{self.base}/v1/identity")
        self._check(r)
        data = r.json()
        return data["identity"], data["token"]

    async def call(self, token: str, reducer: str, args: list) -> None:
        r = await self._http.post(f"{self.base}/v1/database/{self.database}/call/{reducer}",
                                  headers={"Authorization": f"Bearer {token}"}, json=args)
        self._check(r)

    async def query(self, token: str, sql: str) -> list[dict]:
        r = await self._http.post(f"{self.base}/v1/database/{self.database}/sql",
                                  headers={"Authorization": f"Bearer {token}", "Content-Type": "text/plain"},
                                  content=sql.encode())
        self._check(r)
        first = r.json()[0]
        names = [(e.get("name") or {}).get("some", f"col{i}") for i, e in enumerate(first["schema"]["elements"])]
        return [dict(zip(names, (_unwrap(v) for v in row))) for row in first["rows"]]

    async def watch(self, token: str, queries: list[str], on_change: Callable[[], Awaitable[None] | None],
                    stop: asyncio.Event | None = None) -> None:
        """Subscribes to `queries` and calls `on_change` after the initial rows and after every
        transaction that touches them. Reconnects with backoff until cancelled (or `stop` is set)."""
        ws_url = self.base.replace("http", "ws", 1) + f"/v1/database/{self.database}/subscribe"
        tls = ssl.create_default_context(cafile=certifi.where()) if ws_url.startswith("wss") else None
        backoff = 1.0
        while stop is None or not stop.is_set():
            try:
                async with websockets.connect(ws_url, subprotocols=["v1.json.spacetimedb"], ssl=tls,
                                              additional_headers={"Authorization": f"Bearer {token}"},
                                              max_size=None, open_timeout=15) as ws:
                    await ws.send(json.dumps({"SubscribeMulti": {"query_strings": queries, "request_id": 1,
                                                                 "query_id": {"id": 1}}}))
                    async for raw in ws:
                        msg = json.loads(raw)
                        if "SubscriptionError" in msg:
                            raise SpacetimeError(str(msg["SubscriptionError"])[:200])
                        if msg.keys() & {"SubscribeMultiApplied", "TransactionUpdateLight", "TransactionUpdate"}:
                            backoff = 1.0
                            result = on_change()
                            if asyncio.iscoroutine(result):
                                await result
            except asyncio.CancelledError:
                raise
            except Exception as e:  # network blip, auth, server restart: keep trying
                log.info("SpacetimeDB subscription dropped (%s), retrying in %.0fs", str(e)[:120], backoff)
            await asyncio.sleep(backoff)
            backoff = min(backoff * 2, 30.0)

    @staticmethod
    def _check(r: httpx.Response) -> None:
        if r.status_code >= 300:
            raise SpacetimeError(f"{r.status_code}: {r.text[:200]}")


def _unwrap(v):
    """SATS-JSON options are {"some": v} / {"none": []}."""
    if isinstance(v, dict) and len(v) == 1:
        if "some" in v:
            return v["some"]
        if "none" in v:
            return None
    return v


@dataclass
class _MockHousehold:
    id: str
    name: str
    invite_code: str
    members: set[str] = field(default_factory=set)
    items: dict[str, dict] = field(default_factory=dict)  # id -> {"count", "data"}
    shopping: dict[str, str] = field(default_factory=dict)  # id -> data
    uses: list[dict] = field(default_factory=list)          # my_item_uses rows
    approvals: dict[str, dict] = field(default_factory=dict)  # my_approvals rows


class MockSpacetimeClient:
    """In-memory stand-in with the module's reducer semantics (membership checks included)."""
    is_mock = True

    def __init__(self):
        self.tokens: dict[str, str] = {}          # token -> identity
        self.household_of: dict[str, str] = {}    # identity -> household id
        self.households: dict[str, _MockHousehold] = {}
        self.fail_calls = False                   # tests: simulate an outage
        self.fail_reducers = False                # tests: reads work, writes fail

    async def close(self) -> None:
        pass

    async def create_identity(self) -> tuple[str, str]:
        identity, token = uuid.uuid4().hex, "tok-" + uuid.uuid4().hex
        self.tokens[token] = identity
        return identity, token

    def _me(self, token: str) -> str:
        if token not in self.tokens:
            raise SpacetimeError("401: invalid token")
        return self.tokens[token]

    def _hh(self, token: str) -> _MockHousehold:
        me = self._me(token)
        hh = self.households.get(self.household_of.get(me, ""))
        if not hh or me not in hh.members:
            raise SpacetimeError("530: Join or create a household first.")
        return hh

    async def call(self, token: str, reducer: str, args: list) -> None:
        if self.fail_calls or self.fail_reducers:
            raise SpacetimeError("503: mock outage")
        me = self._me(token)
        if reducer == "create_household":
            hid, name = args
            code = uuid.uuid4().hex[:6].upper()
            self.households[hid] = _MockHousehold(hid, name, code, {me})
            self.household_of[me] = hid
        elif reducer == "join_household":
            code = args[0].strip().upper()
            hh = next((h for h in self.households.values() if h.invite_code == code), None)
            if hh is None:
                raise SpacetimeError("530: No household found with that invite code.")
            hh.members.add(me)
            self.household_of[me] = hh.id
        elif reducer == "leave_household":
            hh = self._hh(token)
            hh.members.discard(me)
            self.household_of.pop(me, None)
        elif reducer == "upsert_item":
            item_id, count, data = args
            self._hh(token).items[item_id] = {"count": max(0, count), "data": data}
        elif reducer == "increment_count":
            item_id, delta = args
            item = self._hh(token).items.get(item_id)
            if item is None:
                raise SpacetimeError("530: Item not found.")
            item["count"] = max(0, item["count"] + delta)
        elif reducer == "delete_item":
            self._hh(token).items.pop(args[0], None)
        elif reducer in ("use_item", "log_use"):
            item_id, qty, name = args
            hh = self._hh(token)
            if reducer == "use_item":
                item = hh.items.get(item_id)
                if item is None:
                    raise SpacetimeError("530: Item not found.")
                qty = max(1, min(qty, item["count"] or 1))
                item["count"] -= qty
                if item["count"] <= 0:
                    hh.items.pop(item_id)
            hh.uses.append({"id": len(hh.uses) + 1, "item_id": item_id, "name": name, "qty": qty,
                            "used_by_hex": me, "used_at_ms": 0})
        elif reducer == "post_approval":
            aid, kind, title, detail, money = args
            hh = self._hh(token)
            if aid not in hh.approvals or hh.approvals[aid]["status"] == "open":
                hh.approvals[aid] = {"id": aid, "kind": kind, "title": title, "detail": detail, "money": money,
                                     "status": "open", "decided_by_hex": "", "created_at_ms": 0}
        elif reducer == "decide_approval":
            aid, approve = args
            row = self._hh(token).approvals.get(aid)
            if row is None or row["status"] != "open":
                raise SpacetimeError("530: That question was already answered.")
            row.update(status="approved" if approve else "declined", decided_by_hex=me)
        elif reducer == "close_approval":
            self._hh(token).approvals.pop(args[0], None)
        elif reducer == "save_shopping_item":
            entry_id, data = args
            self._hh(token).shopping[entry_id] = data
        elif reducer == "delete_shopping_item":
            self._hh(token).shopping.pop(args[0], None)
        else:
            raise SpacetimeError(f"mock: unsupported reducer {reducer}")

    async def query(self, token: str, sql: str) -> list[dict]:
        if self.fail_calls:
            raise SpacetimeError("503: mock outage")
        try:
            hh = self._hh(token)
        except SpacetimeError:
            return []
        if "my_items" in sql:
            return [{"id": k, "count": v["count"], "data": v["data"], "updated_at_ms": 0}
                    for k, v in hh.items.items()]
        if "my_approvals" in sql:
            return [dict(a) for a in hh.approvals.values()]
        if "my_item_uses" in sql:
            return [dict(u) for u in hh.uses]
        if "my_shopping" in sql:
            return [{"id": k, "data": v} for k, v in hh.shopping.items()]
        if "my_household" in sql:
            return [{"id": hh.id, "name": hh.name, "invite_code": hh.invite_code, "created_at_ms": 0,
                     "members": sorted(hh.members)}]
        raise SpacetimeError(f"mock: unsupported query {sql}")

    # Test helpers: what the app sees.
    def app_shopping(self, token: str) -> dict[str, dict]:
        return {k: json.loads(v) for k, v in self._hh(token).shopping.items()}

    def app_items(self, token: str) -> dict[str, dict]:
        # The row's count column is authoritative (the JSON copy can be stale), as in the app.
        return {k: {**json.loads(v["data"]), "count": v["count"]} for k, v in self._hh(token).items.items()}
