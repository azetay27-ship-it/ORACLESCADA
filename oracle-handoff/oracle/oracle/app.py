"""Oracle FastAPI application factory and service entry point."""

from __future__ import annotations

from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any, AsyncIterator

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from fastapi.staticfiles import StaticFiles

from .auth import SessionStore
from .models import ErrorEnvelope, OracleAPIError, model_dump
from .routers import auth, commands, health, stream
from .routers import screens
from .routers.state import create_router as create_state_router
from .runtime import ProcessRuntime
from .screen_store import ScreenStore
from .settings import Settings


@asynccontextmanager
async def lifespan(application: FastAPI) -> AsyncIterator[None]:
    settings: Settings = application.state.settings
    runtime = ProcessRuntime(settings)
    application.state.auth = SessionStore(settings)
    application.state.screens = ScreenStore(settings.screen_store)
    application.state.runtime = runtime
    await runtime.initialize()
    await runtime.start()
    try:
        yield
    finally:
        await runtime.stop()
        await application.state.auth.clear()


def _error_payload(error: str, code: str, message: str, details: Any = None) -> dict[str, Any]:
    detail_map = details if isinstance(details, dict) else {}
    envelope = ErrorEnvelope(
        error=error,
        code=code,
        message=message,
        details=details if isinstance(details, dict) else None,
        accepted=detail_map.get("accepted"),
        action=detail_map.get("action"),
        command_id=detail_map.get("commandId", detail_map.get("command_id")),
        state_version=detail_map.get("stateVersion", detail_map.get("state_version")),
    )
    return model_dump(envelope)


def create_app(settings: Settings | None = None) -> FastAPI:
    service_settings = settings or Settings.from_env()
    application = FastAPI(title="Oracle | NILIT SCADA", version="1.0.0", lifespan=lifespan)
    application.state.settings = service_settings

    @application.exception_handler(OracleAPIError)
    async def oracle_error_handler(_request: Request, exc: OracleAPIError) -> JSONResponse:
        return JSONResponse(
            status_code=exc.status_code,
            content=_error_payload(exc.error, exc.code, exc.message, exc.details),
        )

    @application.exception_handler(RequestValidationError)
    async def validation_error_handler(_request: Request, exc: RequestValidationError) -> JSONResponse:
        messages = []
        for item in exc.errors():
            location = ".".join(str(part) for part in item.get("loc", []))
            messages.append(f"{location}: {item.get('msg', 'invalid value')}")
        return JSONResponse(
            status_code=422,
            content=_error_payload("Validation failed", "VALIDATION_ERROR", "; ".join(messages) or "Request validation failed.", {"errors": exc.errors()}),
        )

    @application.exception_handler(Exception)
    async def unexpected_error_handler(_request: Request, _exc: Exception) -> JSONResponse:
        return JSONResponse(status_code=500, content=_error_payload("Internal server error", "INTERNAL_ERROR", "Oracle encountered an unexpected error."))

    application.include_router(auth.router)
    application.include_router(create_state_router())
    application.include_router(commands.router)
    application.include_router(stream.router)
    application.include_router(health.router)
    application.include_router(screens.router)

    public_dir = service_settings.public_dir
    if public_dir.is_dir():
        # API routes are registered first so the catch-all static mount cannot
        # intercept same-origin API calls. Static assets remain read-only.
        application.mount("/", StaticFiles(directory=str(public_dir), html=True), name="public")
    return application


app = create_app()


if __name__ == "__main__":  # pragma: no cover - convenient local entry point
    import uvicorn

    settings = Settings.from_env()
    uvicorn.run("oracle.app:app", host=settings.host, port=settings.port, reload=False)
