from __future__ import annotations

from pathlib import Path

from sqlalchemy import event
from sqlmodel import Session, SQLModel, create_engine

from . import models  # noqa: F401  (registers tables)


def make_engine(url: str):
    if url.startswith("sqlite:///") and ":memory:" not in url:
        Path(url.removeprefix("sqlite:///")).parent.mkdir(parents=True, exist_ok=True)
    engine = create_engine(url, connect_args={"check_same_thread": False})

    @event.listens_for(engine, "connect")
    def _pragmas(conn, _):
        cur = conn.cursor()
        cur.execute("PRAGMA journal_mode=WAL")
        cur.execute("PRAGMA busy_timeout=5000")
        cur.close()

    SQLModel.metadata.create_all(engine)
    return engine


def clear_all(engine, keep: tuple[str, ...] = ()) -> None:
    """Delete every row except in `keep` tables (demo reset). Keeps the schema."""
    with Session(engine) as s:
        for table in reversed(SQLModel.metadata.sorted_tables):
            if table.name not in keep:
                s.exec(table.delete())
        s.commit()
