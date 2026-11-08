"""Pending actions: anything waiting on a human answer (YES/NO, 1/2).

Money only moves through `claim_open`, which flips one open, unexpired action
to `executing` in a single conditional UPDATE, so it can run at most once.
"""
from __future__ import annotations

import json
from datetime import timedelta

from sqlalchemy import update
from sqlmodel import Session, select

from ..models import PendingAction

TTL_MINUTES = 30
MONEY_KINDS = ("transfer", "settle")
OTHER_YES_NO_KINDS = ("bulk_used", "nudge", "add_suggestions", "stock", "claim", "photo_stock")
YES_NO_KINDS = MONEY_KINDS + OTHER_YES_NO_KINDS


def create(s: Session, household_id: int, kind: str, payload: dict, now, minutes: int = TTL_MINUTES) -> PendingAction:
    # A new question replaces older open questions of its own group only: a money offer never
    # silently replaces a fridge question (or the reverse), so a YES can't land on the wrong one.
    if kind in MONEY_KINDS:
        kinds = MONEY_KINDS
    elif kind in OTHER_YES_NO_KINDS:
        kinds = OTHER_YES_NO_KINDS
    else:
        kinds = (kind,)
    for old in s.exec(select(PendingAction).where(PendingAction.household_id == household_id,
                                                  PendingAction.status == "open",
                                                  PendingAction.kind.in_(kinds))):
        old.status = "superseded"
        s.add(old)
    a = PendingAction(household_id=household_id, kind=kind, payload_json=json.dumps(payload),
                      created_at=now, expires_at=now + timedelta(minutes=minutes))
    s.add(a)
    s.flush()
    return a


def latest(s: Session, household_id: int, kinds: tuple[str, ...]) -> PendingAction | None:
    """Most recent open action of these kinds, expired or not (caller checks)."""
    return s.exec(select(PendingAction).where(PendingAction.household_id == household_id,
                                              PendingAction.status == "open",
                                              PendingAction.kind.in_(kinds))
                  .order_by(PendingAction.created_at.desc(), PendingAction.id.desc())).first()


def is_expired(a: PendingAction, now) -> bool:
    return now >= a.expires_at


def payload(a: PendingAction) -> dict:
    return json.loads(a.payload_json or "{}")


def set_status(s: Session, a: PendingAction, status: str) -> None:
    a.status = status
    s.add(a)
    s.flush()


def claim_open(engine, action_id: int, now) -> bool:
    """open + unexpired -> executing, atomically. True only for the one caller that wins."""
    with Session(engine) as s:
        res = s.exec(update(PendingAction)
                     .where(PendingAction.id == action_id, PendingAction.status == "open",
                            PendingAction.expires_at > now)
                     .values(status="executing"))
        s.commit()
        return res.rowcount == 1


def finish(engine, action_id: int, status: str) -> None:
    with Session(engine) as s:
        a = s.get(PendingAction, action_id)
        if a:
            a.status = status
            s.add(a)
            s.commit()


def expire_stale(s: Session, now) -> int:
    n = 0
    for a in s.exec(select(PendingAction).where(PendingAction.status == "open", PendingAction.expires_at <= now)):
        a.status = "expired"
        s.add(a)
        n += 1
    return n


def cancel_open(s: Session, household_id: int, member_id: int | None = None) -> int:
    """STOP: closes this household's open questions (only `member_id`'s when others still listen)."""
    n = 0
    for a in s.exec(select(PendingAction).where(PendingAction.household_id == household_id,
                                                PendingAction.status == "open")):
        owner = payload(a).get("member_id")
        if member_id is None or owner in (None, member_id):
            a.status = "declined"
            s.add(a)
            n += 1
    return n
