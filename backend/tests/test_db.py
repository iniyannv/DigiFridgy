import sqlite3

from sqlmodel import Session

from app.db import make_engine
from app.models import AgentMessage, Household


def test_older_database_gains_new_columns(tmp_path):
    """A database made before a model gained a column keeps working after an upgrade."""
    path = tmp_path / "old.db"
    con = sqlite3.connect(path)
    # agent_messages and households as an earlier version created them.
    con.execute("CREATE TABLE agent_messages (photon_message_id VARCHAR PRIMARY KEY, household_id INTEGER NOT NULL,"
                " space_id VARCHAR NOT NULL, sent_at DATETIME NOT NULL)")
    con.execute("CREATE TABLE households (id INTEGER PRIMARY KEY, name VARCHAR NOT NULL, created_at DATETIME NOT NULL)")
    con.execute("INSERT INTO households (id, name, created_at) VALUES (1, 'Old', '2026-11-01 00:00:00')")
    con.commit()
    con.close()

    engine = make_engine(f"sqlite:///{path}")

    cols = {r[1] for r in sqlite3.connect(path).execute("PRAGMA table_info(agent_messages)")}
    assert "action_id" in cols
    with Session(engine) as s:
        hh = s.get(Household, 1)
        assert hh.weekly_budget == 75.0 and hh.is_demo is False  # defaults filled for old rows
        assert s.get(AgentMessage, "nope") is None
