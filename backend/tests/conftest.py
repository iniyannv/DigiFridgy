import asyncio
import os
import tempfile
from datetime import datetime
from pathlib import Path

# Keep importing app.main from touching the real data directory.
_TMP = tempfile.mkdtemp(prefix="digifridgey-tests-")
os.environ.setdefault("DATABASE_URL", f"sqlite:///{_TMP}/import.db")
os.environ.setdefault("MOCK_NESSIE_PATH", f"{_TMP}/import_nessie.json")
os.environ["RUN_BACKGROUND"] = "false"
for k in ("NESSIE_API_KEY", "PHOTON_API_KEY", "PHOTON_PROJECT_ID", "LLM_API_KEY", "DEMO_TOKEN"):
    os.environ.pop(k, None)

import pytest  # noqa: E402
from sqlmodel import Session, select  # noqa: E402

from app.clock import Clock  # noqa: E402
from app.config import Settings  # noqa: E402
from app.context import Ctx  # noqa: E402
from app.db import make_engine  # noqa: E402
from app.models import Household  # noqa: E402
from app.nessie.client import MockNessieClient  # noqa: E402
from app.photon.client import MockPhotonClient  # noqa: E402

# Saturday Nov 7 2026, 6:00 PM in Chicago.
BASE = datetime(2026, 11, 8, 0, 0)
HANDLE = "+15555550123"


def run(coro):
    return asyncio.run(coro)


@pytest.fixture
def ctx(tmp_path: Path) -> Ctx:
    settings = Settings(
        database_url=f"sqlite:///{tmp_path}/test.db", mock_nessie_path=str(tmp_path / "nessie.json"),
        demo_mode=True, use_mock_nessie=True, use_mock_photon=True, voice_tool_secret="s3cret",
        photon_webhook_secret="", run_background=False, photon_agent_handle="+15550100000",
    )
    engine = make_engine(settings.database_url)
    return Ctx(settings=settings, engine=engine, clock=Clock(settings.tz, engine, base=BASE),
               nessie=MockNessieClient(settings.mock_nessie_path),
               photon=MockPhotonClient(settings.photon_agent_handle))


@pytest.fixture
def seeded(ctx):
    from app.demo.seed import seed
    run(seed(ctx, with_history=False))
    return ctx


def household(ctx) -> Household:
    with Session(ctx.engine) as s:
        return s.exec(select(Household)).first()


def text(ctx, body: str, handle: str = HANDLE) -> str:
    """Simulates a person texting; returns the agent's reply."""
    from app.photon.inbound import handle_raw
    before = len(ctx.photon.outbox)
    raw = ctx.photon.inject(handle, body, created_at=BASE)
    run(handle_raw(ctx, raw))
    new = ctx.photon.outbox[before:]
    return new[-1]["text"] if new else ""


def outbox_texts(ctx) -> list[str]:
    return [m["text"] for m in ctx.photon.outbox]
