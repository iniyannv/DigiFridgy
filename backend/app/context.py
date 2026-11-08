"""Service container passed to every function that touches the outside world."""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from .clock import Clock
from .config import Settings
from .db import make_engine


@dataclass
class Ctx:
    settings: Settings
    engine: Any
    clock: Clock
    nessie: Any   # NessieClient | MockNessieClient
    photon: Any   # PhotonClient | MockPhotonClient
    llm: Any = None  # GeminiLLM | None
    spacetime: Any = None  # SpacetimeClient | MockSpacetimeClient | None (None = no app sync)
    spacetime_wake: Any = None  # asyncio.Event set when either side changed (see spacetime.bridge)
    merchant_cache: dict = field(default_factory=dict)
    _salt: str | None = None


def build_ctx(settings: Settings | None = None) -> Ctx:
    from .brain.llm import GeminiLLM
    from .nessie.client import MockNessieClient, NessieClient
    from .photon.client import MockPhotonClient, PhotonClient

    settings = settings or Settings.from_env()
    engine = make_engine(settings.database_url)
    clock = Clock(settings.tz, engine)
    nessie = (MockNessieClient(settings.mock_nessie_path) if settings.use_mock_nessie
              else NessieClient(settings.nessie_api_key, settings.nessie_base_url))
    photon = (MockPhotonClient(settings.photon_agent_handle or "+15550100000") if settings.use_mock_photon
              else PhotonClient(settings.photon_api_key, settings.photon_project_id, settings.photon_base_url))
    llm = GeminiLLM(settings.llm_api_key, settings.llm_model) if settings.llm_api_key else None
    from .spacetime.client import MockSpacetimeClient, SpacetimeClient
    spacetime = (MockSpacetimeClient() if settings.use_mock_spacetime
                 else SpacetimeClient(settings.spacetime_host, settings.spacetime_db))
    return Ctx(settings=settings, engine=engine, clock=clock, nessie=nessie, photon=photon, llm=llm,
               spacetime=spacetime)
