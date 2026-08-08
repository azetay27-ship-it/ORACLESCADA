"""Public service health route."""

from __future__ import annotations

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse


router = APIRouter()


@router.get("/health")
async def health(request: Request) -> JSONResponse:
    payload = await request.app.state.runtime.health()
    return JSONResponse(status_code=200 if payload.get("ok") else 503, content=payload)
