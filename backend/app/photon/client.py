"""Photon 2.0 (Beta) messaging client over REST, plus an offline mock.

Endpoints (from photon-hq/api openapi.json, server https://api.photon.codes):
  GET  /v1/projects/{id}/messages   listMessages  (createdSince, direction, order, pageSize, platform, pageToken)
  POST /v1/projects/{id}/messages   sendMessage   (header idempotency-key; body spaceId, senderId,
                                                   parentMessageId, content{type,format,text})
Auth: Authorization: Bearer <project API key>.
"""
from __future__ import annotations

import asyncio
import logging
import secrets
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any

import httpx

log = logging.getLogger("photon")


def iso(dt: datetime) -> str:
    """Naive-UTC datetime -> RFC 3339 with milliseconds and Z, as the API expects."""
    if dt.tzinfo is not None:
        dt = dt.astimezone(timezone.utc).replace(tzinfo=None)
    return dt.isoformat(timespec="milliseconds") + "Z"


def parse_ts(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(timezone.utc).replace(tzinfo=None)


@dataclass
class Inbound:
    id: str
    created_at: datetime
    status: str
    platform: str
    sender_id: str
    sender_kind: str
    sender_handle: str
    agent_id: str | None
    agent_kind: str | None
    agent_handle: str | None
    space_id: str
    space_kind: str
    text: str | None  # None when the content isn't plain text (e.g. an image)


def parse_message(m: dict) -> Inbound | None:
    """Reads the public Message JSON. Returns None for shapes we don't handle."""
    try:
        sent, recv, space = m.get("sentBy") or {}, m.get("receivedBy") or {}, m.get("space") or {}
        content = m.get("content") or {}
        text = None
        if content.get("type") == "text" and content.get("format", "plain") == "plain":
            text = content.get("text")
        return Inbound(
            id=m["id"], created_at=parse_ts(m["createdAt"]), status=m.get("status", ""),
            platform=m.get("platform", ""), sender_id=sent.get("id", ""), sender_kind=sent.get("kind", ""),
            sender_handle=sent.get("handle", ""), agent_id=recv.get("id"), agent_kind=recv.get("kind"),
            agent_handle=recv.get("handle"), space_id=space.get("id", ""), space_kind=space.get("kind", ""),
            text=text,
        )
    except (KeyError, TypeError, ValueError):
        return None


class PhotonError(RuntimeError):
    pass


class PhotonClient:
    is_mock = False

    def __init__(self, api_key: str, project_id: str, base_url: str = "https://api.photon.codes"):
        self.project_id = project_id
        self._http = httpx.AsyncClient(base_url=base_url.rstrip("/"), timeout=15.0,
                                       headers={"Authorization": f"Bearer {api_key}"})

    async def close(self) -> None:
        await self._http.aclose()

    async def _call(self, method: str, path: str, **kw) -> Any:
        last = None
        for attempt in range(4):
            try:
                r = await self._http.request(method, path, **kw)
            except httpx.TransportError as exc:
                last = exc
                await asyncio.sleep(1 + attempt)
                continue
            if r.status_code in (429, 502, 503, 504):
                retry_after = r.headers.get("retry-after")
                wait = float(retry_after) if retry_after and retry_after.isdigit() else 1.5 * (attempt + 1)
                last = PhotonError(f"{method} {path} -> {r.status_code}")
                await asyncio.sleep(min(wait, 10))
                continue
            if r.status_code >= 400:
                rid = r.headers.get("x-request-id") or r.headers.get("request-id") or "unknown"
                raise PhotonError(f"{method} {path} -> {r.status_code} (request {rid}): {r.text[:300]}")
            return r.json() if r.content else None
        raise PhotonError(str(last))

    async def list_messages(self, created_since: datetime, platform: str = "imessage",
                            page_token: str | None = None) -> tuple[list[dict], str | None]:
        params = {"createdSince": iso(created_since), "direction": "received", "order": "asc",
                  "pageSize": 100, "platform": platform}
        if page_token:
            params["pageToken"] = page_token
        page = await self._call("GET", f"/v1/projects/{self.project_id}/messages", params=params) or {}
        token = page.get("nextPageToken")
        return page.get("items", []), token if isinstance(token, str) else None

    async def get_message(self, message_id: str) -> dict:
        return await self._call("GET", f"/v1/projects/{self.project_id}/messages/{message_id}")

    async def list_assignments(self) -> list[dict]:
        """Active shared-line assignments (needs platforms:read)."""
        out, token = [], None
        while True:
            params = {"pageSize": 100, **({"pageToken": token} if token else {})}
            page = await self._call("GET", f"/v1/projects/{self.project_id}/platforms/imessage/assignments",
                                    params=params) or {}
            out += page.get("assignments", [])
            token = page.get("nextPageToken")
            if not isinstance(token, str):
                return out

    async def assign_line(self, handle: str, idempotency_key: str, first_name: str | None = None,
                          last_name: str | None = None) -> dict:
        """Maps a person's phone/email onto a pooled shared iMessage line (needs platforms:write).
        Returns the assignment, including `assignedPhoneNumber` (the number they should text)."""
        body = {"handle": handle}
        if first_name:
            body["firstName"] = first_name[:100]
        if last_name:
            body["lastName"] = last_name[:100]
        return await self._call("POST", f"/v1/projects/{self.project_id}/platforms/imessage/assignments",
                                headers={"Idempotency-Key": idempotency_key}, json=body)

    async def send_message(self, space_id: str, sender_id: str, text: str, idempotency_key: str,
                           parent_message_id: str | None = None) -> dict:
        body: dict[str, Any] = {"spaceId": space_id, "senderId": sender_id,
                                "content": {"type": "text", "format": "plain", "text": text}}
        if parent_message_id:
            body["parentMessageId"] = parent_message_id
        return await self._call("POST", f"/v1/projects/{self.project_id}/messages",
                                headers={"idempotency-key": idempotency_key}, json=body)


def _pid(prefix: str) -> str:
    alphabet = "0123456789abcdefghjkmnpqrstvwxyz"
    return f"pho_{prefix}_0" + "".join(secrets.choice(alphabet) for _ in range(25))


class MockPhotonClient:
    """SIMULATED iMessage. `inject` plays the role of a person texting; sends are
    recorded (and printed) instead of delivered. Same JSON shapes as the real API."""

    is_mock = True

    def __init__(self, agent_handle: str = "+15550100000"):
        self.agent_handle = agent_handle
        self.agent_id = _pid("usr")
        self.inbox: list[dict] = []
        self.outbox: list[dict] = []
        self._users: dict[str, str] = {}
        self._spaces: dict[str, str] = {}
        self._keys: set[str] = set()
        self.assignments: dict[str, dict] = {}

    async def close(self) -> None:
        pass

    def space_for(self, handle: str) -> str:
        return self._spaces.setdefault(handle, _pid("spc"))

    def inject(self, handle: str, text: str, created_at: datetime | None = None) -> dict:
        created_at = created_at or datetime.now(timezone.utc).replace(tzinfo=None)
        msg = {
            "id": _pid("msg"), "platform": "imessage", "status": "received", "createdAt": iso(created_at),
            "sentBy": {"id": self._users.setdefault(handle, _pid("usr")), "kind": "human", "handle": handle,
                       "platform": "imessage"},
            "receivedBy": {"id": self.agent_id, "kind": "agent", "handle": self.agent_handle,
                           "platform": "imessage"},
            "space": {"id": self.space_for(handle), "kind": "direct", "platform": "imessage"},
            "content": {"type": "text", "format": "plain", "text": text},
        }
        self.inbox.append(msg)
        return msg

    async def list_messages(self, created_since: datetime, platform: str = "imessage",
                            page_token: str | None = None) -> tuple[list[dict], str | None]:
        return [m for m in self.inbox if parse_ts(m["createdAt"]) >= created_since], None

    async def list_assignments(self) -> list[dict]:
        return list(self.assignments.values())

    async def assign_line(self, handle: str, idempotency_key: str, first_name: str | None = None,
                          last_name: str | None = None) -> dict:
        if handle not in self.assignments:
            self.assignments[handle] = {"assignmentId": _pid("asg"), "handle": handle, "platform": "imessage",
                                        "assignedPhoneNumber": self.agent_handle, "simulated": True}
            log.info("[SIMULATED Photon] assigned %s to %s", self.agent_handle, handle)
        return self.assignments[handle]

    async def get_message(self, message_id: str) -> dict:
        for m in self.inbox:
            if m["id"] == message_id:
                return m
        raise PhotonError("SIMULATED: not found")

    async def send_message(self, space_id: str, sender_id: str, text: str, idempotency_key: str,
                           parent_message_id: str | None = None) -> dict:
        if idempotency_key in self._keys:
            return {"id": "replayed", "idempotentReplayed": True}
        self._keys.add(idempotency_key)
        handle = next((h for h, sp in self._spaces.items() if sp == space_id), space_id)
        rec = {"id": _pid("msg"), "spaceId": space_id, "handle": handle, "senderId": sender_id, "text": text,
               "parentMessageId": parent_message_id, "idempotencyKey": idempotency_key,
               "createdAt": iso(datetime.now(timezone.utc).replace(tzinfo=None))}
        self.outbox.append(rec)
        log.info("[SIMULATED iMessage -> %s]\n%s", handle, text)
        return rec

    def conversation(self, handle: str) -> list[dict]:
        space = self._spaces.get(handle)
        rows = [{"from": "user", "text": m["content"]["text"], "at": m["createdAt"]}
                for m in self.inbox if m["sentBy"]["handle"] == handle]
        rows += [{"from": "agent", "text": m["text"], "at": m["createdAt"]}
                 for m in self.outbox if m["spaceId"] == space]
        return sorted(rows, key=lambda r: r["at"])
