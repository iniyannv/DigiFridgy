"""Capital One Nessie API client (live) and an offline mock with the same interface.

Paths and fields follow Nessie's official SDK (github.com/nessieisreal). Every
call goes through this file, so a field mismatch found against the live API is
fixed in one place. The key is always passed as the `key` query parameter.
"""
from __future__ import annotations

import asyncio
import json
import logging
import secrets
import threading
from pathlib import Path
from typing import Any

import httpx

log = logging.getLogger("nessie")


class NessieError(RuntimeError):
    pass


def _created_id(resp_json: Any) -> str:
    """POSTs return {"code": 201, "message": ..., "objectCreated": {"_id": ...}}."""
    if isinstance(resp_json, dict):
        obj = resp_json.get("objectCreated") or resp_json
        if isinstance(obj, dict) and obj.get("_id"):
            return obj["_id"]
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
                       params: dict | None = None) -> Any:
        q = {"key": self.api_key, **(params or {})}
        last: Exception | None = None
        for attempt in range(3):
            try:
                r = await self._http.request(method, path, params=q, json=json_body)
            except httpx.TransportError as exc:
                last = exc
            else:
                if r.status_code < 500:
                    if r.status_code >= 400:
                        raise NessieError(f"{method} {path} -> {r.status_code}: {r.text[:300]}")
                    return r.json() if r.content else None
                last = NessieError(f"{method} {path} -> {r.status_code}: {r.text[:300]}")
            await asyncio.sleep(0.5 * (attempt + 1))
        raise NessieError(str(last))

    # Customers
    async def get_customers(self) -> list[dict]:
        return await self._request("GET", "/customers") or []

    async def create_customer(self, first_name: str, last_name: str, address: dict) -> str:
        body = {"first_name": first_name, "last_name": last_name, "address": address}
        return _created_id(await self._request("POST", "/customers", json_body=body))

    # Accounts
    async def get_customer_accounts(self, customer_id: str) -> list[dict]:
        return await self._request("GET", f"/customers/{customer_id}/accounts") or []

    async def create_account(self, customer_id: str, type: str, nickname: str, balance: float) -> str:
        body = {"type": type, "nickname": nickname, "rewards": 0, "balance": int(round(balance))}
        return _created_id(await self._request("POST", f"/customers/{customer_id}/accounts", json_body=body))

    async def get_account(self, account_id: str) -> dict:
        return await self._request("GET", f"/accounts/{account_id}")

    # Merchants
    async def create_merchant(self, name: str, category: str, address: dict, geocode: dict) -> str:
        body = {"name": name, "category": [category], "address": address, "geocode": geocode}
        return _created_id(await self._request("POST", "/merchants", json_body=body))

    async def get_merchant(self, merchant_id: str) -> dict:
        return await self._request("GET", f"/merchants/{merchant_id}")

    # Purchases
    async def create_purchase(self, account_id: str, merchant_id: str, amount: float,
                              purchase_date: str, description: str) -> str:
        body = {
            "merchant_id": merchant_id,
            "medium": "balance",
            "purchase_date": purchase_date,
            "amount": round(amount, 2),
            "status": "completed",
            "description": description,
        }
        return _created_id(await self._request("POST", f"/accounts/{account_id}/purchases", json_body=body))

    async def list_purchases(self, account_id: str) -> list[dict]:
        return await self._request("GET", f"/accounts/{account_id}/purchases") or []

    # Transfers
    async def create_transfer(self, from_account_id: str, to_account_id: str, amount: float,
                              description: str, transaction_date: str) -> str:
        body = {
            "medium": "balance",
            "payee_id": to_account_id,
            "amount": round(amount, 2),
            "transaction_date": transaction_date,
            "status": "completed",
            "description": description,
        }
        return _created_id(await self._request("POST", f"/accounts/{from_account_id}/transfers", json_body=body))

    async def delete_data(self, type_: str) -> None:
        """Deletes ALL data of this type for the API key (shared by the whole team)."""
        await self._request("DELETE", "/data", params={"type": type_})


class MockNessieClient:
    """SIMULATED Nessie. State persists to a JSON file so the seed script,
    CLI and server share it. Purchases and transfers update balances at once."""

    is_mock = True

    def __init__(self, path: str | None):
        self.path = Path(path) if path else None
        self._lock = threading.Lock()
        self.state = self._load()

    def _load(self) -> dict:
        empty = {"customers": {}, "accounts": {}, "merchants": {}, "purchases": {}, "transfers": {}}
        if self.path and self.path.exists():
            try:
                return {**empty, **json.loads(self.path.read_text())}
            except json.JSONDecodeError:
                pass
        return empty

    def _save(self) -> None:
        if self.path:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            self.path.write_text(json.dumps(self.state, indent=1))

    def _reload(self) -> None:
        # Another process (seed/CLI) may have written the file.
        if self.path and self.path.exists():
            self.state = self._load()

    @staticmethod
    def _new_id() -> str:
        return secrets.token_hex(12)  # looks like a Mongo ObjectId, as Nessie uses

    async def close(self) -> None:
        pass

    async def get_customers(self) -> list[dict]:
        with self._lock:
            self._reload()
            return list(self.state["customers"].values())

    async def create_customer(self, first_name: str, last_name: str, address: dict) -> str:
        with self._lock:
            self._reload()
            cid = self._new_id()
            self.state["customers"][cid] = {"_id": cid, "first_name": first_name, "last_name": last_name,
                                            "address": address, "simulated": True}
            self._save()
            return cid

    async def get_customer_accounts(self, customer_id: str) -> list[dict]:
        with self._lock:
            self._reload()
            return [a for a in self.state["accounts"].values() if a["customer_id"] == customer_id]

    async def create_account(self, customer_id: str, type: str, nickname: str, balance: float) -> str:
        with self._lock:
            self._reload()
            aid = self._new_id()
            self.state["accounts"][aid] = {"_id": aid, "type": type, "nickname": nickname, "rewards": 0,
                                           "balance": round(balance, 2), "customer_id": customer_id,
                                           "simulated": True}
            self._save()
            return aid

    async def get_account(self, account_id: str) -> dict:
        with self._lock:
            self._reload()
            if account_id not in self.state["accounts"]:
                raise NessieError(f"SIMULATED: no account {account_id}")
            return dict(self.state["accounts"][account_id])

    async def create_merchant(self, name: str, category: str, address: dict, geocode: dict) -> str:
        with self._lock:
            self._reload()
            mid = self._new_id()
            self.state["merchants"][mid] = {"_id": mid, "name": name, "category": [category],
                                            "address": address, "geocode": geocode, "simulated": True}
            self._save()
            return mid

    async def get_merchant(self, merchant_id: str) -> dict:
        with self._lock:
            self._reload()
            if merchant_id not in self.state["merchants"]:
                raise NessieError(f"SIMULATED: no merchant {merchant_id}")
            return dict(self.state["merchants"][merchant_id])

    async def create_purchase(self, account_id: str, merchant_id: str, amount: float,
                              purchase_date: str, description: str) -> str:
        with self._lock:
            self._reload()
            if account_id not in self.state["accounts"]:
                raise NessieError(f"SIMULATED: no account {account_id}")
            pid = self._new_id()
            self.state["purchases"][pid] = {"_id": pid, "type": "merchant", "merchant_id": merchant_id,
                                            "payer_id": account_id, "purchase_date": purchase_date,
                                            "amount": round(amount, 2), "status": "completed",
                                            "medium": "balance", "description": description,
                                            "simulated": True}
            acct = self.state["accounts"][account_id]
            acct["balance"] = round(acct["balance"] - amount, 2)
            self._save()
            return pid

    async def list_purchases(self, account_id: str) -> list[dict]:
        with self._lock:
            self._reload()
            return [p for p in self.state["purchases"].values() if p["payer_id"] == account_id]

    async def create_transfer(self, from_account_id: str, to_account_id: str, amount: float,
                              description: str, transaction_date: str) -> str:
        with self._lock:
            self._reload()
            src = self.state["accounts"].get(from_account_id)
            dst = self.state["accounts"].get(to_account_id)
            if not src or not dst:
                raise NessieError("SIMULATED: unknown account")
            tid = self._new_id()
            self.state["transfers"][tid] = {"_id": tid, "type": "p2p", "payer_id": from_account_id,
                                            "payee_id": to_account_id, "amount": round(amount, 2),
                                            "transaction_date": transaction_date, "status": "completed",
                                            "medium": "balance", "description": description,
                                            "simulated": True}
            src["balance"] = round(src["balance"] - amount, 2)
            dst["balance"] = round(dst["balance"] + amount, 2)
            self._save()
            log.info("SIMULATED Nessie transfer $%.2f %s -> %s", amount, from_account_id, to_account_id)
            return tid

    async def delete_data(self, type_: str) -> None:
        key = {"Customers": "customers", "Accounts": "accounts", "Purchases": "purchases",
               "Transfers": "transfers"}.get(type_)
        with self._lock:
            if key:
                self.state[key] = {}
            self._save()

    def wipe(self) -> None:
        with self._lock:
            self.state = {"customers": {}, "accounts": {}, "merchants": {}, "purchases": {}, "transfers": {}}
            self._save()
