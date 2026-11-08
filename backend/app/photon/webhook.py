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
    secret = ctx.settings.photon_webhook_secret
    if not secret:
        return Response(status_code=404)
    body = await request.body()
    headers = {k: request.headers.get(k, "") for k in ("webhook-id", "webhook-timestamp", "webhook-signature")}
    try:
        event = Webhook(secret).verify(body, headers)
    except WebhookVerificationError:
        return Response(status_code=400)
    if not claim(ctx, f"wh:{headers['webhook-id']}"):
        return Response(status_code=204)  # duplicate delivery we already accepted
    message = find_message(event)
    if message is not None:
        asyncio.create_task(handle_raw(ctx, message))
    else:
        log.info("webhook event without a message: %s", str(event)[:200])
    return Response(status_code=204)
