"""FastAPI app: HTTP routes plus three background loops
(Photon poll, Nessie purchase sync, scheduler).

    uvicorn app.main:app --reload --port 8000
"""
from __future__ import annotations

import asyncio
import contextlib
import logging

from fastapi import FastAPI

from .context import build_ctx
from .demo.routes import page_router as demo_page_router
from .demo.routes import router as demo_router
from .nessie.sync import sync_loop
from .photon.inbound import poll_loop
from .photon.webhook import router as webhook_router
from .scheduler.jobs import scheduler_loop
from .voice.tools import router as voice_router

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
log = logging.getLogger("main")


@contextlib.asynccontextmanager
async def lifespan(app: FastAPI):
    ctx = app.state.ctx
    st = ctx.settings
    log.info("DigiFridgey starting | Nessie: %s | Photon: %s | LLM: %s | DEMO_MODE=%s",
             "SIMULATED" if ctx.nessie.is_mock else "live",
             "SIMULATED" if ctx.photon.is_mock else "live",
             st.llm_model if ctx.llm else "off (keywords only)", st.demo_mode)
    tasks = []
    if st.run_background:
        tasks = [asyncio.create_task(poll_loop(ctx), name="photon-poll"),
                 asyncio.create_task(sync_loop(ctx), name="nessie-sync"),
                 asyncio.create_task(scheduler_loop(ctx), name="scheduler")]
    yield
    for t in tasks:
        t.cancel()
    for client in (ctx.nessie, ctx.photon, ctx.llm):
        if client is not None:
            await client.close()


def create_app(ctx=None) -> FastAPI:
    ctx = ctx or build_ctx()
    app = FastAPI(title="DigiFridgey", lifespan=lifespan)
    app.state.ctx = ctx
    app.include_router(webhook_router)
    app.include_router(voice_router)
    if ctx.settings.demo_mode:
        app.include_router(demo_router)
        app.include_router(demo_page_router)

    @app.get("/health")
    async def health():
        return {"ok": True, "nessie": "mock" if ctx.nessie.is_mock else "live",
                "photon": "mock" if ctx.photon.is_mock else "live", "llm": ctx.llm is not None}

    return app


app = create_app()
