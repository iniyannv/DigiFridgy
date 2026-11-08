"""Photon webhook receiver (P1). Polling stays on as the fallback.

Verifies Standard Webhooks signatures against the raw body, dedupes on
`webhook-id`, returns 204 fast and handles the message in the background.
The event body is the public event JSON; we look for the Message object
inside it and run it through the same handler as polling (which dedupes by
message ID, so polling and webhooks never double-reply).
"""
from __future__ import annotations

import asyncio
import logging

from fastapi import APIRouter, Request, Response
from standardwebhooks.webhooks import Webhook, WebhookVerificationError

from .inbound import claim, handle_raw

log = logging.getLogger("webhook")
router = APIRouter()
SECRET_KEY = "photon:webhook_secret"


def stored_secret(ctx) -> str:
    from sqlmodel import Session

    from ..models import NessieObject
    with Session(ctx.engine) as s:
        row = s.get(NessieObject, SECRET_KEY)
        return row.nessie_id if row else ""


async def register(ctx) -> str:
    """With PUBLIC_URL set and Photon live: creates the webhook destination (once) and keeps its signing
    secret, so replies arrive by push instead of the 2 s poll. Polling stays on as the fallback."""
    from sqlmodel import Session

    from ..models import NessieObject
    url = f"{ctx.settings.public_url}/photon/webhook"
    dest, secret = await ctx.photon.ensure_webhook(url)
    if secret:
        with Session(ctx.engine) as s:
            s.merge(NessieObject(key=SECRET_KEY, nessie_id=secret))
            s.commit()
        return f"registered {url} ({dest})"
    if ctx.settings.photon_webhook_secret or stored_secret(ctx):
        return f"already registered: {url}"
    return (f"a destination for {url} exists but its signing secret isn't known here; "
            "set PHOTON_WEBHOOK_SECRET from the Photon dashboard")


def find_message(obj, depth: int = 0) -> dict | None:
    """First dict that looks like a Message (has id, sentBy, space)."""
    if depth > 5:
        return None
    if isinstance(obj, dict):
        if {"id", "sentBy", "space"} <= obj.keys():
            return obj
        for v in obj.values():
            found = find_message(v, depth + 1)
            if found:
                return found
    elif isinstance(obj, list):
        for v in obj:
            found = find_message(v, depth + 1)
            if found:
                return found
    return None


@router.post("/photon/webhook")
async def photon_webhook(request: Request) -> Response:
    ctx = request.app.state.ctx
    secret = ctx.settings.photon_webhook_secret or stored_secret(ctx)
    if not secret:
        return Response(status_code=404)
    body = await request.body()
    headers = {k: request.headers.get(k, "") for k in ("webhook-id", "webhook-timestamp", "webhook-signature")}
    try:
        event = Webhook(secret).verify(body, headers)
    except WebhookVerificationError:
        return Response(status_code=400)
    import time
    ctx.webhook_seen_at = time.monotonic()
    if not claim(ctx, f"wh:{headers['webhook-id']}"):
        return Response(status_code=204)  # duplicate delivery we already accepted
    message = find_message(event)
    if message is not None:
        asyncio.create_task(handle_raw(ctx, message))
    else:
        kind = event.get("type") if isinstance(event, dict) else type(event).__name__
        log.info("webhook event without a message (type %s)", kind)
    return Response(status_code=204)
