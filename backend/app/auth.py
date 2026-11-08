"""Who is calling, for the HTTP routes.

Three kinds of caller:

- **The demo token** (`DEMO_TOKEN`, header `X-Demo-Token`): the shared secret the app build and the
  presenter's demo page carry. It only proves "someone allowed to drive this demo". It ships inside
  the app bundle, so it never decides whose money moves or whose data is returned.
- **An app user** (header `Authorization: Bearer <SpacetimeDB token>`): the iPhone app's own
  SpacetimeDB token (anonymous identity or Firebase ID token). The server asks SpacetimeDB who that
  is (`my_profile`, `my_household`), so the caller can't claim to be someone else.
- **The operator** (header `X-Admin-Token` matching `ADMIN_TOKEN`, or any loopback request while
  `ADMIN_TOKEN` is unset): the presenter's console. It may pick any household.

Without `DEMO_TOKEN`, only loopback requests are served: a server reachable from the network has to
set it.
"""
from __future__ import annotations

import hashlib
import hmac
import logging
import time
from dataclasses import dataclass

from fastapi import HTTPException, Request
from sqlmodel import Session

log = logging.getLogger("auth")

LOOPBACK = {"127.0.0.1", "::1", "localhost", "testclient"}
CALLER_TTL_S = 60.0


def same_secret(given: str | None, expected: str) -> bool:
    """Constant-time compare on bytes, so non-ASCII input is a mismatch, not a crash."""
    return hmac.compare_digest((given or "").encode("utf-8"), expected.encode("utf-8"))


def is_loopback(request: Request) -> bool:
    """A request from this machine that no proxy or tunnel forwarded."""
    if request.headers.get("x-forwarded-for") or request.headers.get("forwarded"):
        return False
    host = request.client.host if request.client else ""
    return host in LOOPBACK


def require_demo_token(request: Request) -> None:
    settings = request.app.state.ctx.settings
    if not settings.demo_token:
        if is_loopback(request):
            return
        raise HTTPException(403, "This server has no DEMO_TOKEN, so it only answers this computer. "
                                 "Set DEMO_TOKEN on the server and DIGIFRIDGEY_TOKEN in the app.")
    if not same_secret(request.headers.get("x-demo-token"), settings.demo_token):
        raise HTTPException(401, "bad demo token")


def is_operator(request: Request) -> bool:
    admin = request.app.state.ctx.settings.admin_token
    if admin:
        return same_secret(request.headers.get("x-admin-token"), admin)
    return is_loopback(request)


def require_operator(request: Request) -> None:
    if not is_operator(request):
        raise HTTPException(403, "Only the demo operator can do that.")


@dataclass(frozen=True)
class AppCaller:
    identity: str            # lowercase hex, no 0x
    app_household_id: str    # "" when the caller isn't in a household
    bank_household_id: int | None  # their own bank (Connect your bank), if any


_cache: dict[str, tuple[float, str, str]] = {}


def bearer(request: Request) -> str | None:
    raw = request.headers.get("authorization") or ""
    if raw[:7].lower() != "bearer ":
        return None
    return raw[7:].strip() or None


async def verify_app_token(ctx, token: str) -> tuple[str, str]:
    """(identity hex, app household id) for a SpacetimeDB token, asked of SpacetimeDB itself."""
    key = hashlib.sha256(token.encode()).hexdigest()
    hit = _cache.get(key)
    now = time.monotonic()
    if hit and now - hit[0] < CALLER_TTL_S:
        return hit[1], hit[2]
    if ctx.spacetime is None:
        raise HTTPException(503, "The app connection isn't set up on this server.")
    try:
        profile = await ctx.spacetime.query(token, "SELECT * FROM my_profile")
    except Exception as exc:
        log.info("app token rejected: %s", str(exc)[:120])
        raise HTTPException(401, "The app's sign-in token was rejected.")
    if not profile:
        raise HTTPException(401, "Open the app and sign in first.")
    from .money import norm_identity
    identity = norm_identity(profile[0].get("identity_hex"))
    rows = await ctx.spacetime.query(token, "SELECT * FROM my_household")
    app_household_id = str(rows[0].get("id")) if rows else ""
    _cache[key] = (now, identity, app_household_id)
    return identity, app_household_id


async def app_caller(request: Request, required: bool = True) -> AppCaller | None:
    token = bearer(request)
    if not token:
        if required:
            raise HTTPException(401, "Sign in to the app first (missing app token).")
        return None
    ctx = request.app.state.ctx
    identity, app_household_id = await verify_app_token(ctx, token)
    from .models import AppMember
    with Session(ctx.engine) as s:
        m = s.get(AppMember, identity)
        bank = m.household_id if m else None
    return AppCaller(identity, app_household_id, bank)


def clear_cache() -> None:
    _cache.clear()
