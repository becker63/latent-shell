import asyncio
import os
import time
from collections import deque
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import HTMLResponse, JSONResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles
from pydantic_ai.models import Model

from .codex_model import CodexModel, authenticated_transport
from .boot import stream_world
from .page import PAGE
from .world import (
    WorldRequest,
    create_world_agent,
    generate_world,
    manifest,
)

MAX_BODY_BYTES = 256 * 1024


class BodyLimit:
    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http" or scope["method"] != "POST":
            return await self.app(scope, receive, send)
        body = bytearray()
        while True:
            message = await receive()
            if message["type"] == "http.disconnect":
                return
            body.extend(message.get("body", b""))
            if len(body) > MAX_BODY_BYTES:
                return await JSONResponse({"error": "request too large"}, 413)(
                    scope, receive, send
                )
            if not message.get("more_body", False):
                break
        consumed = False

        async def replay():
            nonlocal consumed
            if not consumed:
                consumed = True
                return {"type": "http.request", "body": bytes(body), "more_body": False}
            return await receive()

        await self.app(scope, replay, send)


def create_app(
    test_model: Model | None = None, static_dir: Path | None = None
) -> FastAPI:
    assets = static_dir or Path(os.environ.get("LATENT_STATIC_DIR", "build/static"))

    @asynccontextmanager
    async def lifespan(app):
        if test_model is not None:
            app.state.world_agent = create_world_agent(test_model)
            yield
            return
        required = ("shell.wasm", "host.js", "xterm.js", "xterm.css", "xterm-fit.js")
        if not all((assets / name).is_file() for name in required):
            raise RuntimeError(
                "LATENT_STATIC_DIR must point to the complete Nix static runtime"
            )
        async with authenticated_transport() as codex:
            app.state.world_agent = create_world_agent(CodexModel(codex))
            yield

    app = FastAPI(lifespan=lifespan, docs_url=None, redoc_url=None, openapi_url=None)
    app.add_middleware(BodyLimit)
    app.mount("/static", StaticFiles(directory=assets, check_dir=False), name="static")

    @app.get("/", response_class=HTMLResponse)
    async def page():
        return PAGE

    arrivals: deque[float] = deque()
    slots = asyncio.Semaphore(4)

    @app.exception_handler(RequestValidationError)
    async def validation_error(request, exc):
        return JSONResponse({"error": "invalid world request"}, 422)

    @app.get("/manifest")
    async def get_manifest():
        return manifest()

    @app.post("/world")
    async def create_world(payload: WorldRequest, request: Request):
        now = time.monotonic()
        while arrivals and arrivals[0] <= now - 60:
            arrivals.popleft()
        if len(arrivals) >= 10:
            return JSONResponse(
                {"error": "request limit reached"}, 429, headers={"Retry-After": "60"}
            )
        arrivals.append(now)
        if slots.locked():
            return JSONResponse({"error": "world generator busy"}, 503)
        if "application/x-ndjson" in request.headers.get("accept", ""):
            return StreamingResponse(
                stream_world(app.state.world_agent, payload, slots),
                media_type="application/x-ndjson",
                headers={"Cache-Control": "no-store", "X-Accel-Buffering": "no"},
            )
        try:
            async with slots, asyncio.timeout(90):
                image = await generate_world(app.state.world_agent, payload)
        except TimeoutError:
            return JSONResponse({"error": "world generation timed out"}, 504)
        except Exception:
            return JSONResponse({"error": "world generation failed"}, 502)
        return {"version": 1, "image": image.model_dump(mode="json")}

    return app


app = create_app()
