from __future__ import annotations

import logging
from pathlib import Path

from sqlalchemy import event
from sqlmodel import Session, SQLModel, create_engine

from . import models  # noqa: F401  (registers tables)

log = logging.getLogger("db")


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
    add_missing_columns(engine)
    return engine


def add_missing_columns(engine) -> list[str]:
    """`create_all` makes missing tables but never changes existing ones, so a database from an older
    version lacks columns added to a model since. Adds those (nullable, or with a plain default).
    Returns "table.column" for each one added."""
    if engine.dialect.name != "sqlite":
        return []
    added = []
    with engine.begin() as conn:
        for table in SQLModel.metadata.sorted_tables:
            have = {row[1] for row in conn.exec_driver_sql(f'PRAGMA table_info("{table.name}")')}
            for col in table.columns:
                if col.name in have:
                    continue
                default = col.default.arg if col.default is not None and col.default.is_scalar else None
                if not col.nullable and default is None:
                    log.warning("can't add required column %s.%s to an existing database", table.name, col.name)
                    continue
                ddl = f'ALTER TABLE "{table.name}" ADD COLUMN "{col.name}" {col.type.compile(engine.dialect)}'
                if default is not None:
                    ddl += f" DEFAULT {_sql_literal(default)}"
                conn.exec_driver_sql(ddl)
                added.append(f"{table.name}.{col.name}")
    if added:
        log.info("added columns to the existing database: %s", ", ".join(added))
    return added


def _sql_literal(value) -> str:
    if isinstance(value, bool):
        return "1" if value else "0"
    if isinstance(value, (int, float)):
        return repr(value)
    return "'" + str(value).replace("'", "''") + "'"


def clear_all(engine, keep: tuple[str, ...] = ()) -> None:
    """Delete every row except in `keep` tables (demo reset). Keeps the schema."""
    with Session(engine) as s:
        for table in reversed(SQLModel.metadata.sorted_tables):
            if table.name not in keep:
                s.exec(table.delete())
        s.commit()
