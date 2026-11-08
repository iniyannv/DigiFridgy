"""Settings loaded from the environment (and backend/.env when present)."""
from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path
from zoneinfo import ZoneInfo

from dotenv import load_dotenv

BACKEND_DIR = Path(__file__).resolve().parent.parent
load_dotenv(BACKEND_DIR / ".env")


def _bool(name: str, default: bool) -> bool:
    raw = os.environ.get(name, "").strip().lower()
    if raw in ("1", "true", "yes", "on"):
        return True
    if raw in ("0", "false", "no", "off"):
        return False
    return default


def _list(name: str) -> list[str]:
    return [p.strip() for p in os.environ.get(name, "").split(",") if p.strip()]


@dataclass
class Settings:
    nessie_api_key: str = ""
    nessie_base_url: str = "https://prod-api.nessieisreal.com"
    photon_api_key: str = ""
    photon_project_id: str = ""
    photon_base_url: str = "https://api.photon.codes"
    photon_platform: str = "imessage"
    photon_agent_handle: str = ""
    photon_webhook_secret: str = ""
    public_url: str = ""  # e.g. https://abc.trycloudflare.com: registers the Photon webhook at startup
    voice_tool_secret: str = ""
    llm_api_key: str = ""
    llm_model: str = "gemini-2.5-flash"
    demo_mode: bool = True
    demo_token: str = ""
    admin_token: str = ""  # presenter-only actions (reset with wipe_nessie, picking any household)
    timezone: str = "America/Chicago"
    use_mock_nessie: bool = True
    use_mock_photon: bool = True
    allowed_handles: list[str] = field(default_factory=list)
    database_url: str = f"sqlite:///{BACKEND_DIR / 'data' / 'digifridgey.db'}"
    mock_nessie_path: str = str(BACKEND_DIR / "data" / "mock_nessie.json")
    run_background: bool = True
    # False: new card purchases wait for the person to add them (YES by text, or Add from card in the app).
    auto_stock: bool = False
    # SpacetimeDB: the iOS app's database, so iMessage and the app share one fridge.
    spacetime_host: str = ""
    spacetime_db: str = ""
    use_mock_spacetime: bool = True

    @property
    def tz(self) -> ZoneInfo:
        return ZoneInfo(self.timezone)

    @property
    def sync_interval(self) -> float:
        return 5.0 if self.demo_mode else 60.0

    @property
    def scheduler_interval(self) -> float:
        return 5.0 if self.demo_mode else 60.0

    @property
    def spacetime_interval(self) -> float:
        return 3.0 if self.demo_mode else 15.0

    @property
    def photon_poll_interval(self) -> float:
        return 2.0

    @classmethod
    def from_env(cls) -> "Settings":
        e = os.environ.get
        nessie_key = e("NESSIE_API_KEY", "")
        photon_key = e("PHOTON_API_KEY", "")
        photon_project = e("PHOTON_PROJECT_ID", "")
        return cls(
            nessie_api_key=nessie_key,
            nessie_base_url=e("NESSIE_BASE_URL", "") or cls.nessie_base_url,
            photon_api_key=photon_key,
            photon_project_id=photon_project,
            photon_base_url=e("PHOTON_BASE_URL", "") or cls.photon_base_url,
            photon_platform=e("PHOTON_PLATFORM", "") or "imessage",
            photon_agent_handle=e("PHOTON_AGENT_HANDLE", ""),
            photon_webhook_secret=e("PHOTON_WEBHOOK_SECRET", ""),
            public_url=e("PUBLIC_URL", "").rstrip("/"),
            voice_tool_secret=e("VOICE_TOOL_SECRET", ""),
            llm_api_key=e("LLM_API_KEY", ""),
            llm_model=e("LLM_MODEL", "") or cls.llm_model,
            demo_mode=_bool("DEMO_MODE", True),
            demo_token=e("DEMO_TOKEN", ""),
            admin_token=e("ADMIN_TOKEN", ""),
            timezone=e("TIMEZONE", "") or cls.timezone,
            # Mocks turn on automatically when a key is missing; set false to force live.
            use_mock_nessie=_bool("USE_MOCK_NESSIE", not nessie_key),
            use_mock_photon=_bool("USE_MOCK_PHOTON", not (photon_key and photon_project)),
            allowed_handles=_list("ALLOWED_HANDLES"),
            database_url=e("DATABASE_URL", "") or cls.database_url,
            mock_nessie_path=e("MOCK_NESSIE_PATH", "") or cls.mock_nessie_path,
            run_background=_bool("RUN_BACKGROUND", True),
            auto_stock=_bool("AUTO_STOCK", False),
            spacetime_host=e("SPACETIME_HOST", ""),
            spacetime_db=e("SPACETIME_DB", ""),
            use_mock_spacetime=_bool("USE_MOCK_SPACETIME", not (e("SPACETIME_HOST", "") and e("SPACETIME_DB", ""))),
        )
