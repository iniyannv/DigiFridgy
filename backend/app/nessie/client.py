"""Capital One Nessie API client (live) and an offline mock with the same interface.

Behavior verified against https://prod-api.nessieisreal.com (Nov 2026):
- The key goes in the `key` query parameter. IDs are UUIDs.
- Money amounts and balances are stored as whole dollars (cents are dropped).
- Merchant `category` is a single string.
- Account balances never change: purchases, transfers and deposits are stored
  as records only, and PUT /accounts ignores `balance`. So the app computes a
  running balance from those records (see `running_balance`).
- A transfer has no destination field (only date, status, amount, description),
  so moving money is recorded as a transfer out of the source account plus a
  matching deposit into the destination account.
- Empty lists come back as 404 "No ... found for this account".
Every call goes through this file, so API differences are fixed in one place.
"""
from __future__ import annotations

import asyncio
import json
import logging
import threading
import uuid
from pathlib import Path
from typing import Any

import httpx

log = logging.getLogger("nessie")


class NessieError(RuntimeError):
    pass


def whole_dollars(amount: float) -> int:
    """Nessie truncates amounts; do it ourselves so what we show matches what it stores."""
    return int(amount)


def _created_id(resp_json: Any) -> str:
    """POSTs return {"code": 201, "message": ..., "objectCreated": {"_id": ...}}."""
    if isinstance(resp_json, dict):
        obj = resp_json.get("objectCreated") or resp_json
        if isinstance(obj, dict) and (obj.get("_id") or obj.get("id")):
            return obj.get("_id") or obj["id"]
    raise NessieError(f"Unexpected create response: {resp_json!r}")


class NessieClient:
    is_mock = False

    def __init__(self, api_key: str, base_url: str):
        self.api_key = api_key
        self.base_url = base_url.rstrip("/")
        self._http = httpx.AsyncClient(base_url=self.base_url, timeout=15.0)

    async def close(self) -> None:
        await self._http.aclose()

    async def _request(self, method: str, path: str, *, json_body: Any = None,
                       params: dict | None = None, empty_404: bool = False) -> Any:
        q = {"key": self.api_key, **(params or {})}
        last: Exception | None = None
        for attempt in range(3):
            try:
                r = await self._http.request(method, path, params=q, json=json_body)
            except httpx.TransportError as exc:
                last = exc
            else:
                if empty_404 and r.status_code == 404:
                    return []
                if r.status_code < 500:
                    if r.status_code >= 400:
                        raise NessieError(f"{method} {path} -> {r.status_code}: {r.text[:300]}")
                    return r.json() if r.content else None
                last = NessieError(f"{method} {path} -> {r.status_code}: {r.text[:300]}")
            await asyncio.sleep(0.5 * (attempt + 1))
        raise NessieError(str(last))

    async def _list(self, path: str) -> list[dict]:
        data = await self._request("GET", path, empty_404=True)
        return data if isinstance(data, list) else []

    # Customers
    async def get_customers(self) -> list[dict]:
        return await self._list("/customers")

    async def create_customer(self, first_name: str, last_name: str, address: dict) -> str:
        body = {"first_name": first_name, "last_name": last_name, "address": address}
        return _created_id(await self._request("POST", "/customers", json_body=body))

    # Accounts
    async def get_customer_accounts(self, customer_id: str) -> list[dict]:
        return await self._list(f"/customers/{customer_id}/accounts")

    async def create_account(self, customer_id: str, type: str, nickname: str, balance: float) -> str:
        body = {"type": type, "nickname": nickname, "rewards": 0, "balance": whole_dollars(balance)}
        return _created_id(await self._request("POST", f"/customers/{customer_id}/accounts", json_body=body))

    async def get_account(self, account_id: str) -> dict:
        return await self._request("GET", f"/accounts/{account_id}")

    # Merchants
    async def create_merchant(self, name: str, category: str, address: dict, geocode: dict) -> str:
        body = {"name": name, "category": category, "address": address, "geocode": geocode}
        return _created_id(await self._request("POST", "/merchants", json_body=body))

    async def get_merchant(self, merchant_id: str) -> dict:
        return await self._request("GET", f"/merchants/{merchant_id}")

    # Purchases
    async def create_purchase(self, account_id: str, merchant_id: str, amount: float,
                              purchase_date: str, description: str) -> str:
        body = {"merchant_id": merchant_id, "medium": "balance", "purchase_date": purchase_date,
                "amount": whole_dollars(amount), "status": "completed", "description": description}
        return _created_id(await self._request("POST", f"/accounts/{account_id}/purchases", json_body=body))

    async def list_purchases(self, account_id: str) -> list[dict]:
        return await self._list(f"/accounts/{account_id}/purchases")

    # Transfers and deposits
    async def create_transfer(self, from_account_id: str, to_account_id: str, amount: float,
                              description: str, transaction_date: str) -> str:
        """Transfer out of `from` plus a matching deposit into `to` (Nessie transfers have no payee)."""
        dollars = whole_dollars(amount)
        out = {"transaction_date": transaction_date, "status": "completed", "amount": dollars,
               "description": f"{description} (to account {to_account_id})"}
        tid = _created_id(await self._request("POST", f"/accounts/{from_account_id}/transfers", json_body=out))
        dep = {"medium": "balance", "transaction_date": transaction_date, "status": "completed", "amount": dollars,
               "description": f"{description} (transfer {tid} from account {from_account_id})"}
        await self._request("POST", f"/accounts/{to_account_id}/deposits", json_body=dep)
        return tid

    async def list_transfers(self, account_id: str) -> list[dict]:
        return await self._list(f"/accounts/{account_id}/transfers")

    async def list_deposits(self, account_id: str) -> list[dict]:
        return await self._list(f"/accounts/{account_id}/deposits")

    async def delete_data(self, type_: str) -> None:
        """Deletes ALL data of this type for the API key (shared by the whole team), if supported."""
        await self._request("DELETE", "/data", params={"type": type_})


async def running_balance(nessie, account_id: str) -> float:
    """Opening balance minus purchases and transfers out, plus deposits, all from Nessie's records."""
    acct = await nessie.get_account(account_id)
    purchases = await nessie.list_purchases(account_id)
    transfers = await nessie.list_transfers(account_id)
    deposits = await nessie.list_deposits(account_id)
    total = float(acct.get("balance") or 0)
    total -= sum(float(p.get("amount") or 0) for p in purchases if p.get("status") != "cancelled")
    total -= sum(float(t.get("amount") or 0) for t in transfers if t.get("status") != "cancelled")
    total += sum(float(d.get("amount") or 0) for d in deposits if d.get("status") != "cancelled")
    return round(total, 2)


class MockNessieClient:
    """SIMULATED Nessie that behaves like the live API (whole dollars, static
    balances, transfer + deposit). State persists to a JSON file so the seed
    script, CLI and server share it."""

    is_mock = True
    KINDS = ("customers", "accounts", "merchants", "purchases", "transfers", "deposits")

    def __init__(self, path: str | None):
        self.path = Path(path) if path else None
        self._lock = threading.Lock()
        self.state = self._load()

    def _empty(self) -> dict:
        return {k: {} for k in self.KINDS}

    def _load(self) -> dict:
        if self.path and self.path.exists():
            try:
                return {**self._empty(), **json.loads(self.path.read_text())}
            except json.JSONDecodeError:
                pass
        return self._empty()

    def _save(self) -> None:
        if self.path:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            self.path.write_text(json.dumps(self.state, indent=1))

    def _reload(self) -> None:
        # Another process (seed/CLI) may have written the file.
        if self.path and self.path.exists():
            self.state = self._load()

    def _add(self, kind: str, obj: dict) -> str:
        with self._lock:
            self._reload()
            oid = str(uuid.uuid4())
            self.state[kind][oid] = {"_id": oid, **obj, "simulated": True}
            self._save()
            return oid

    def _where(self, kind: str, **match) -> list[dict]:
        with self._lock:
            self._reload()
            return [dict(o) for o in self.state[kind].values() if all(o.get(k) == v for k, v in match.items())]

    def _get(self, kind: str, oid: str) -> dict:
        with self._lock:
            self._reload()
            if oid not in self.state[kind]:
                raise NessieError(f"SIMULATED: no {kind[:-1]} {oid}")
            return dict(self.state[kind][oid])

    async def close(self) -> None:
        pass

    async def get_customers(self) -> list[dict]:
        return self._where("customers")

    async def create_customer(self, first_name: str, last_name: str, address: dict) -> str:
        return self._add("customers", {"first_name": first_name, "last_name": last_name, "address": address})

    async def get_customer_accounts(self, customer_id: str) -> list[dict]:
        return self._where("accounts", customer_id=customer_id)

    async def create_account(self, customer_id: str, type: str, nickname: str, balance: float) -> str:
        return self._add("accounts", {"type": type, "nickname": nickname, "rewards": 0,
                                      "balance": whole_dollars(balance), "customer_id": customer_id})

    async def get_account(self, account_id: str) -> dict:
        return self._get("accounts", account_id)

    async def create_merchant(self, name: str, category: str, address: dict, geocode: dict) -> str:
        return self._add("merchants", {"name": name, "category": category, "address": address, "geocode": geocode})

    async def get_merchant(self, merchant_id: str) -> dict:
        return self._get("merchants", merchant_id)

    async def create_purchase(self, account_id: str, merchant_id: str, amount: float,
                              purchase_date: str, description: str) -> str:
        self._get("accounts", account_id)
        return self._add("purchases", {"type": "merchant", "merchant_id": merchant_id, "payer_id": account_id,
                                       "purchase_date": purchase_date, "amount": whole_dollars(amount),
                                       "status": "completed", "medium": "balance", "description": description})

    async def list_purchases(self, account_id: str) -> list[dict]:
        return self._where("purchases", payer_id=account_id)

    async def create_transfer(self, from_account_id: str, to_account_id: str, amount: float,
                              description: str, transaction_date: str) -> str:
        self._get("accounts", from_account_id)
        self._get("accounts", to_account_id)
        dollars = whole_dollars(amount)
        tid = self._add("transfers", {"account_id": from_account_id, "transaction_date": transaction_date,
                                      "status": "completed", "amount": dollars,
                                      "description": f"{description} (to account {to_account_id})"})
        self._add("deposits", {"account_id": to_account_id, "medium": "balance", "transaction_date": transaction_date,
                               "status": "completed", "amount": dollars,
                               "description": f"{description} (transfer {tid} from account {from_account_id})"})
        log.info("SIMULATED Nessie transfer $%d %s -> %s", dollars, from_account_id, to_account_id)
        return tid

    async def list_transfers(self, account_id: str) -> list[dict]:
        return self._where("transfers", account_id=account_id)

    async def list_deposits(self, account_id: str) -> list[dict]:
        return self._where("deposits", account_id=account_id)

    async def delete_data(self, type_: str) -> None:
        key = type_.lower()
        with self._lock:
            if key in self.state:
                self.state[key] = {}
            self._save()

    def wipe(self) -> None:
        with self._lock:
            self.state = self._empty()
            self._save()
