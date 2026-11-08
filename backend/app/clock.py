"""The only source of "now" for app logic, so the demo can time-skip.

All stored timestamps are naive UTC. Use `to_local` for display and for
calendar math (weeks, "tomorrow").
"""
from __future__ import annotations

from datetime import date, datetime, timedelta, timezone
from zoneinfo import ZoneInfo

from sqlmodel import Session

from .models import ClockOffset


class Clock:
    def __init__(self, tz: ZoneInfo, engine=None, base: datetime | None = None, time_skip: bool = True):
        self.tz = tz
        self.engine = engine
        self.base = base  # fixed "real now" for tests (naive UTC)
        self.offset = timedelta(0)
        # The demo time-skip only exists in DEMO_MODE: a database reused for a real run must not
        # carry an offset into transfer dates and budget weeks.
        self.time_skip = time_skip
        if engine is not None and time_skip:
            with Session(engine) as s:
                row = s.get(ClockOffset, 1)
                if row:
                    self.offset = timedelta(seconds=row.offset_seconds)

    def real_now(self) -> datetime:
        if self.base is not None:
            return self.base
        return datetime.now(timezone.utc).replace(tzinfo=None)

    def now(self) -> datetime:
        """Simulated now, naive UTC."""
        return self.real_now() + self.offset

    def local_now(self) -> datetime:
        return self.to_local(self.now())

    def today(self) -> date:
        return self.local_now().date()

    def to_local(self, dt: datetime) -> datetime:
        return dt.replace(tzinfo=timezone.utc).astimezone(self.tz)

    def local_to_utc(self, dt: datetime) -> datetime:
        """Local wall-clock (naive or aware) to naive UTC."""
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=self.tz)
        return dt.astimezone(timezone.utc).replace(tzinfo=None)

    def week_start(self, d: date | None = None) -> date:
        d = d or self.today()
        return d - timedelta(days=d.weekday())  # Monday

    def advance(self, days: float = 0, hours: float = 0) -> None:
        if not self.time_skip:
            raise RuntimeError("time-skip is only available in DEMO_MODE")
        if days < 0 or hours < 0:
            raise ValueError("time only moves forward")  # a rewind would reopen expired offers
        self.offset += timedelta(days=days, hours=hours)
        self._save()

    def reset(self) -> None:
        self.offset = timedelta(0)
        self._save()

    def _save(self) -> None:
        if self.engine is None:
            return
        with Session(self.engine) as s:
            row = s.get(ClockOffset, 1) or ClockOffset(id=1)
            row.offset_seconds = int(self.offset.total_seconds())
            s.add(row)
            s.commit()
