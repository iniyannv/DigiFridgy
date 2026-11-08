"""Photon 2.0 (Beta) messaging client over REST, plus an offline mock.

Endpoints (from photon-hq/api openapi.json, server https://api.photon.codes):
  GET  /v1/projects/{id}/messages   listMessages  (createdSince, direction, order, pageSize, platform, pageToken)
  POST /v1/projects/{id}/messages   sendMessage   (header idempotency-key; body spaceId, senderId,
                                                   parentMessageId, content{type,format,text})
  GET  /v1/projects/{id}/attachments/{attachmentId}[/content]   attachment metadata / bytes
  POST /v1/projects/{id}/spaces/{spaceId}/typing                {senderId, typing}
  POST /v1/projects/{id}/users                 createOrGetUser  {handle, platform} -> User {id, handle}
  POST /v1/projects/{id}/spaces                createOrGetSpace (header idempotency-key; body participantIds,
                                               platform). For iMessage the first participant must be a
                                               project-owned DEDICATED line: shared lines can't start a chat.
  GET  /v1/projects/{id}/spaces/{spaceId}      Space {id, kind, participantIds}; GET /users/{userId} -> handle
  GET/POST /v1/projects/{id}/webhooks/destinations              webhook destinations (signingSecret on create)
Inbound content: text, attachment {attachmentId}, reaction {reaction, action} (parentMessageId = the
message reacted to). Spaces have a `kind`: "direct" for 1:1, anything else is a group.
Auth: Authorization: Bearer <project API key>.
"""
from __future__ import annotations

import asyncio
import logging
import secrets
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any

import uuid

import httpx

log = logging.getLogger("photon")


def _mask(handle: str | None) -> str:
    from ..signup import mask
    return mask(handle)


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
    content_type: str = "text"            # text | attachment | reaction | other
    attachment_id: str | None = None
    reaction: str | None = None
    reaction_action: str | None = None    # add | remove
    parent_message_id: str | None = None

    @property
    def is_group(self) -> bool:
        return self.space_kind != "direct"


def parse_message(m: dict) -> Inbound | None:
    """Reads the public Message JSON. Returns None for shapes we don't handle."""
    try:
        sent, recv, space = m.get("sentBy") or {}, m.get("receivedBy") or {}, m.get("space") or {}
        content = m.get("content") or {}
        text = None
        ctype = content.get("type") or "other"
        if ctype == "text" and content.get("format", "plain") == "plain":
            text = content.get("text")
        elif ctype == "group":  # text + attachment sent together: use the first of each
            for part in content.get("parts") or []:
                part = part.get("content", part) if isinstance(part, dict) else {}
                if part.get("type") == "attachment" and not content.get("attachmentId"):
                    content = {**content, "attachmentId": part.get("attachmentId")}
                    ctype = "attachment"
                elif part.get("type") == "text" and text is None:
                    text = part.get("text")
            if ctype == "group":
                ctype = "text" if text else "other"
        return Inbound(
            id=m["id"], created_at=parse_ts(m["createdAt"]), status=m.get("status", ""),
            platform=m.get("platform", ""), sender_id=sent.get("id", ""), sender_kind=sent.get("kind", ""),
            sender_handle=sent.get("handle", ""), agent_id=recv.get("id"), agent_kind=recv.get("kind"),
            agent_handle=recv.get("handle"), space_id=space.get("id", ""), space_kind=space.get("kind", ""),
            text=text, content_type=ctype if ctype in ("text", "attachment", "reaction") else "other",
            attachment_id=content.get("attachmentId"), reaction=content.get("reaction"),
            reaction_action=content.get("action"), parent_message_id=m.get("parentMessageId"),
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
        if method.upper() == "POST":
            # Photon requires an idempotency key on every POST; reuse one across retries.
            headers = dict(kw.get("headers") or {})
            if not any(k.lower() == "idempotency-key" for k in headers):
                headers["Idempotency-Key"] = str(uuid.uuid4())
            kw["headers"] = headers
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

    async def create_or_get_user(self, handle: str, platform: str = "imessage") -> str:
        user = await self._call("POST", f"/v1/projects/{self.project_id}/users",
                                json={"handle": handle, "platform": platform}) or {}
        return (user.get("user") or user)["id"]

    async def create_group(self, agent_user_id: str, handles: list[str], idempotency_key: str,
                           platform: str = "imessage") -> dict:
        """Starts a group chat with these people. Only works from a dedicated line (the agent goes first);
        on a shared line Photon refuses and the caller falls back to instructions."""
        ids = [agent_user_id] + [await self.create_or_get_user(h, platform) for h in handles]
        space = await self._call("POST", f"/v1/projects/{self.project_id}/spaces",
                                 headers={"idempotency-key": idempotency_key},
                                 json={"participantIds": list(dict.fromkeys(ids)), "platform": platform}) or {}
        return space.get("space") or space

    async def space_handles(self, space_id: str) -> list[str]:
        """Handles of the people in a space (not agents). Best effort: one lookup per participant."""
        space = await self._call("GET", f"/v1/projects/{self.project_id}/spaces/{space_id}") or {}
        space = space.get("space") or space
        out = []
        for uid in (space.get("participantIds") or [])[:12]:
            user = await self._call("GET", f"/v1/projects/{self.project_id}/users/{uid}") or {}
            user = user.get("user") or user
            if user.get("kind", "human") != "agent" and user.get("handle"):
                out.append(user["handle"])
        return out

    async def set_typing(self, space_id: str, sender_id: str, typing: bool = True) -> None:
        await self._call("POST", f"/v1/projects/{self.project_id}/spaces/{space_id}/typing",
                         json={"senderId": sender_id, "typing": typing})

    async def get_attachment(self, attachment_id: str) -> dict:
        return await self._call("GET", f"/v1/projects/{self.project_id}/attachments/{attachment_id}") or {}

    async def download_attachment(self, attachment_id: str, max_bytes: int = 8_000_000) -> bytes:
        path = f"/v1/projects/{self.project_id}/attachments/{attachment_id}/content"
        for attempt in range(4):  # ATTACHMENT_NOT_READY comes back with Retry-After
            r = await self._http.get(path, timeout=30.0, follow_redirects=True)
            if r.status_code in (409, 503) and attempt < 3:
                retry = r.headers.get("retry-after", "5")
                await asyncio.sleep(min(float(retry) if retry.replace(".", "").isdigit() else 5, 10))
                continue
            if r.status_code >= 400:
                raise PhotonError(f"download attachment -> {r.status_code}: {r.text[:200]}")
            if len(r.content) > max_bytes:
                raise PhotonError("attachment too large")
            return r.content
        raise PhotonError("attachment not ready")

    async def ensure_webhook(self, url: str) -> tuple[str, str | None]:
        """Creates a webhook destination for every event at `url`, unless one exists.
        Returns (destination id, signing secret). The secret only comes back on create."""
        base = f"/v1/projects/{self.project_id}/webhooks"
        listed = await self._call("GET", f"{base}/destinations") or {}
        for d in listed.get("destinations") or listed.get("items") or []:
            if d.get("url") == url and not d.get("deletedAt"):
                return d.get("destinationId", ""), None
        versions = await self._call("GET", f"{base}/api-versions") or {}
        found = [v if isinstance(v, str) else (v.get("version") or v.get("apiVersion") or v.get("id"))
                 for v in (versions.get("versions") or versions.get("items") or versions.get("apiVersions") or [])]
        api_version = versions.get("current") or versions.get("latest") or (found[-1] if found else None)
        body = {"name": "digifridgey", "url": url, "enabledEvents": ["*"], "apiVersion": api_version}
        created = await self._call("POST", f"{base}/destinations", json=body) or {}
        return (created.get("destination") or {}).get("destinationId", ""), created.get("signingSecret")


def _pid(prefix: str) -> str:
    alphabet = "0123456789abcdefghjkmnpqrstvwxyz"
    return f"pho_{prefix}_0" + "".join(secrets.choice(alphabet) for _ in range(25))


class MockPhotonClient:
    """SIMULATED iMessage. `inject` plays the role of a person texting; sends are
    recorded (and printed) instead of delivered. Same JSON shapes as the real API."""

    is_mock = True

    def __init__(self, agent_handle: str = "+15550100000", dedicated: bool = False):
        self.agent_handle = agent_handle
        self.dedicated = dedicated          # a dedicated line can start group chats; a shared one can't
        self.participants: dict[str, list[str]] = {}   # group space id -> handles in it
        self.agent_id = _pid("usr")
        self.inbox: list[dict] = []
        self.outbox: list[dict] = []
        self._users: dict[str, str] = {}
        self._spaces: dict[str, str] = {}
        self._keys: set[str] = set()
        self.assignments: dict[str, dict] = {}
        self.attachments: dict[str, tuple[str, bytes]] = {}   # id -> (content type, bytes)
        self.typing: list[str] = []                            # spaces we showed typing in

    async def close(self) -> None:
        pass

    def space_for(self, handle: str) -> str:
        return self._spaces.setdefault(handle, _pid("spc"))

    def inject(self, handle: str, text: str | None = None, created_at: datetime | None = None, *,
               group: str | None = None, image: bytes | None = None, image_type: str = "image/jpeg",
               reaction: str | None = None, parent_id: str | None = None,
               members: list[str] | None = None) -> dict:
        """A person texting. `group` names a group chat (shared space); `members` are the other people
        in that group; `image` sends a photo; `reaction` + `parent_id` sends a tapback on one of our messages."""
        created_at = created_at or datetime.now(timezone.utc).replace(tzinfo=None)
        if reaction:
            content = {"type": "reaction", "reaction": reaction, "action": "add"}
        elif image is not None:
            att = _pid("att")
            self.attachments[att] = (image_type, image)
            content = {"type": "attachment", "attachmentId": att}
        else:
            content = {"type": "text", "format": "plain", "text": text}
        space = ({"id": self._spaces.setdefault(f"group:{group}", _pid("spc")), "kind": "group",
                  "platform": "imessage"} if group else
                 {"id": self.space_for(handle), "kind": "direct", "platform": "imessage"})
        msg = {
            "id": _pid("msg"), "platform": "imessage", "status": "received", "createdAt": iso(created_at),
            "sentBy": {"id": self._users.setdefault(handle, _pid("usr")), "kind": "human", "handle": handle,
                       "platform": "imessage"},
            "receivedBy": {"id": self.agent_id, "kind": "agent", "handle": self.agent_handle,
                           "platform": "imessage"},
            "space": space,
            "content": content,
        }
        if parent_id:
            msg["parentMessageId"] = parent_id
        if group:
            people = self.participants.setdefault(space["id"], [])
            for h in [handle, *(members or [])]:
                if h not in people:
                    people.append(h)
        self.inbox.append(msg)
        return msg

    async def space_handles(self, space_id: str) -> list[str]:
        return list(self.participants.get(space_id, []))

    async def create_group(self, agent_user_id: str, handles: list[str], idempotency_key: str,
                           platform: str = "imessage") -> dict:
        if not self.dedicated:
            raise PhotonError("SIMULATED: a shared line can't start a group chat (needs a dedicated line)")
        key = "group:" + ",".join(sorted(handles))
        space_id = self._spaces.setdefault(key, _pid("spc"))
        self.participants[space_id] = list(dict.fromkeys(handles))
        log.info("[SIMULATED Photon] started a group with %d people", len(handles))
        return {"id": space_id, "kind": "group", "platform": platform}

    async def set_typing(self, space_id: str, sender_id: str, typing: bool = True) -> None:
        self.typing.append(space_id)

    async def get_attachment(self, attachment_id: str) -> dict:
        if attachment_id not in self.attachments:
            raise PhotonError("SIMULATED: no such attachment")
        ctype, data = self.attachments[attachment_id]
        return {"id": attachment_id, "contentType": ctype, "sizeBytes": len(data)}

    async def download_attachment(self, attachment_id: str, max_bytes: int = 8_000_000) -> bytes:
        return self.attachments[attachment_id][1]

    async def ensure_webhook(self, url: str) -> tuple[str, str | None]:
        return "SIMULATED", None

    def group_conversation(self, group: str) -> list[dict]:
        space = self._spaces.get(f"group:{group}")
        return [m for m in self.outbox if m["spaceId"] == space]

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
            log.info("[SIMULATED Photon] assigned %s to %s", self.agent_handle, _mask(handle))
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
        log.info("[SIMULATED iMessage -> %s] %d chars", _mask(handle), len(text))
        log.debug("[SIMULATED iMessage text]\n%s", text)
        return rec

    def conversation(self, handle: str) -> list[dict]:
        space = self._spaces.get(handle)
        rows = [{"from": "user", "text": m["content"].get("text") or f"[{m['content']['type']}]", "at": m["createdAt"]}
                for m in self.inbox if m["sentBy"]["handle"] == handle and m["space"]["kind"] == "direct"]
        rows += [{"from": "agent", "text": m["text"], "at": m["createdAt"]}
                 for m in self.outbox if m["spaceId"] == space]
        return sorted(rows, key=lambda r: r["at"])
