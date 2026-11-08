"""Moving money exactly once.

Nessie has no idempotency keys, and a transfer is two calls (transfer out, then deposit in). So:

1. `claim` inserts a `TransferClaim` row with a unique key before anything is sent. A second caller
   with the same key (double tap, second worker, retry) gets `duplicate` and sends nothing.
2. The Nessie description carries a marker made from the key. If a call fails without a clear
   rejection (timeout, 5xx), the transfer list is checked for the marker before calling it failed.
3. If the transfer went out but the deposit didn't, the claim is `deposit_pending` and the
   scheduler retries only the deposit (`retry_deposits`).
"""
from __future__ import annotations

import hashlib
import logging
from dataclasses import dataclass

from sqlalchemy import update
from sqlalchemy.exc import IntegrityError
from sqlmodel import Session, select

from .context import Ctx
from .models import TransferClaim
from .nessie.client import NessieError, PartialTransfer, whole_dollars

log = logging.getLogger("transfers")


@dataclass
class Outcome:
    status: str  # done | deposit_pending | failed | duplicate | unknown
    transfer_id: str | None = None

    @property
    def money_left(self) -> bool:
        return self.status in ("done", "deposit_pending")


def marker(key: str) -> str:
    return "[dfg:" + hashlib.sha256(key.encode()).hexdigest()[:12] + "]"


def _claim(ctx: Ctx, key: str, from_account: str, to_account: str, amount: int, description: str,
           transaction_date: str) -> bool:
    """True if this caller owns the claim. A claim that failed cleanly can be taken again."""
    now = ctx.clock.real_now()
    with Session(ctx.engine) as s:
        s.add(TransferClaim(key=key, from_account=from_account, to_account=to_account, amount=amount,
                            description=description, transaction_date=transaction_date, created_at=now))
        try:
            s.commit()
            return True
        except IntegrityError:
            s.rollback()
        res = s.exec(update(TransferClaim).where(TransferClaim.key == key, TransferClaim.status == "failed")
                     .values(status="pending", from_account=from_account, to_account=to_account, amount=amount,
                             description=description, transaction_date=transaction_date, updated_at=now))
        s.commit()
        return res.rowcount == 1


def _finish(ctx: Ctx, key: str, status: str, transfer_id: str | None = None) -> None:
    with Session(ctx.engine) as s:
        row = s.get(TransferClaim, key)
        if row:
            row.status = status
            row.nessie_transfer_id = transfer_id or row.nessie_transfer_id
            row.updated_at = ctx.clock.real_now()
            s.add(row)
            s.commit()


async def _find(nessie, account_id: str, mark: str, kind: str) -> str | None:
    rows = await (nessie.list_transfers(account_id) if kind == "transfer" else nessie.list_deposits(account_id))
    hit = next((r for r in rows if mark in (r.get("description") or "")), None)
    return (hit.get("_id") or hit.get("id") or "?") if hit else None


async def _deposit(ctx: Ctx, row: TransferClaim, transfer_id: str) -> bool:
    """Sends the matching deposit unless Nessie already has it. True when the deposit exists."""
    mark = marker(row.key)
    desc = f"{row.description} {mark} (transfer {transfer_id} from account {row.from_account})"
    try:
        await ctx.nessie.create_deposit(row.to_account, row.amount, desc, row.transaction_date)
        return True
    except NessieError as exc:
        if exc.definitely_rejected:
            return False
    except Exception:
        pass
    try:
        return await _find(ctx.nessie, row.to_account, mark, "deposit") is not None
    except Exception:
        return False


async def move(ctx: Ctx, key: str, from_account: str, to_account: str, amount: float, description: str,
               transaction_date: str) -> Outcome:
    dollars = whole_dollars(amount)
    if not _claim(ctx, key, from_account, to_account, dollars, description, transaction_date):
        return Outcome("duplicate")
    mark = marker(key)
    try:
        tid = await ctx.nessie.create_transfer(from_account, to_account, dollars, f"{description} {mark}",
                                               transaction_date)
    except PartialTransfer as exc:
        with Session(ctx.engine) as s:
            row = s.get(TransferClaim, key)
        ok = await _deposit(ctx, row, exc.transfer_id)
        status = "done" if ok else "deposit_pending"
        _finish(ctx, key, status, exc.transfer_id)
        log.warning("transfer %s: deposit %s", exc.transfer_id, "sent on retry" if ok else "still pending")
        return Outcome(status, exc.transfer_id)
    except Exception as exc:
        if isinstance(exc, NessieError) and exc.definitely_rejected:
            _finish(ctx, key, "failed")
            log.warning("transfer rejected: %s", exc)
            return Outcome("failed")
        # Timeout or 5xx: the transfer may exist. Look before calling it failed.
        try:
            tid = await _find(ctx.nessie, from_account, mark, "transfer")
        except Exception:
            # Unknown: the claim stays `pending`, so nothing sends it again until someone checks.
            log.exception("couldn't check whether transfer %s landed", key)
            return Outcome("unknown")
        if tid is None:
            _finish(ctx, key, "failed")
            return Outcome("failed")
        with Session(ctx.engine) as s:
            row = s.get(TransferClaim, key)
        ok = await _deposit(ctx, row, tid)
        status = "done" if ok else "deposit_pending"
        _finish(ctx, key, status, tid)
        return Outcome(status, tid)
    _finish(ctx, key, "done", tid)
    return Outcome("done", tid)


async def retry_deposits(ctx: Ctx) -> int:
    """Scheduler: finishes transfers whose deposit didn't go through. Returns how many finished."""
    with Session(ctx.engine) as s:
        rows = list(s.exec(select(TransferClaim).where(TransferClaim.status == "deposit_pending")))
    done = 0
    for row in rows:
        if await _deposit(ctx, row, row.nessie_transfer_id or "?"):
            _finish(ctx, row.key, "done")
            done += 1
    return done
