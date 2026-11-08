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
from .signup import router as signup_router
from .spacetime.bridge import sync_loop as spacetime_loop
from .spacetime.bridge import watch_loop as spacetime_watch
from .voice.tools import router as voice_router

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
log = logging.getLogger("main")
# httpx logs full request URLs, and Nessie's key is a query parameter: keep it out of logs.
logging.getLogger("httpx").setLevel(logging.WARNING)


@contextlib.asynccontextmanager
async def lifespan(app: FastAPI):
    ctx = app.state.ctx
    st = ctx.settings
    log.info("DigiFridgey starting | Nessie: %s | Photon: %s | App sync (SpacetimeDB): %s | LLM: %s | DEMO_MODE=%s",
             "SIMULATED" if ctx.nessie.is_mock else "live",
             "SIMULATED" if ctx.photon.is_mock else "live",
             _spacetime_label(ctx), st.llm_model if ctx.llm else "off (keywords only)", st.demo_mode)
    if st.demo_mode and not st.demo_token:
        log.warning("DEMO_TOKEN is not set: the demo and bank routes only answer requests from this computer. "
                    "Set DEMO_TOKEN (and DIGIFRIDGEY_TOKEN in the app) to use them over the network.")
    if not st.admin_token:
        log.info("ADMIN_TOKEN is not set: demo reset works from this computer only, and wiping Nessie is off.")
    tasks = []
    try:
        from .card import backfill
        n = await backfill(ctx)
        if n:
            log.info("card review: saved product lines for %d earlier purchase(s)", n)
    except Exception:
        log.exception("card backfill failed")
    if st.run_background:
        tasks = [asyncio.create_task(poll_loop(ctx), name="photon-poll"),
                 asyncio.create_task(sync_loop(ctx), name="nessie-sync"),
                 asyncio.create_task(scheduler_loop(ctx), name="scheduler")]
        if ctx.spacetime is not None:
            tasks.append(asyncio.create_task(spacetime_loop(ctx), name="spacetime-sync"))
            tasks.append(asyncio.create_task(spacetime_watch(ctx), name="spacetime-watch"))
    yield
    for t in tasks:
        t.cancel()
    for client in (ctx.nessie, ctx.photon, ctx.llm, ctx.spacetime):
        if client is not None:
            await client.close()


def _spacetime_label(ctx) -> str:
    if ctx.spacetime is None:
        return "off"
    if ctx.spacetime.is_mock:
        return "SIMULATED"
    return f"live ({ctx.settings.spacetime_db})"


def create_app(ctx=None) -> FastAPI:
    ctx = ctx or build_ctx()
    app = FastAPI(title="DigiFridgey", lifespan=lifespan)
    app.state.ctx = ctx
    app.include_router(webhook_router)
    app.include_router(signup_router)
    app.include_router(voice_router)
    if ctx.settings.demo_mode:
        app.include_router(demo_router)
        app.include_router(demo_page_router)

    @app.get("/health")
    async def health():
        return {"ok": True, "nessie": "mock" if ctx.nessie.is_mock else "live",
                "photon": "mock" if ctx.photon.is_mock else "live", "llm": ctx.llm is not None,
                "spacetime": _spacetime_label(ctx).split(" ")[0].lower()}

    return app


app = create_app()
