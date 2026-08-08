"""Authenticated state snapshot route."""

from __future__ import annotations

from fastapi import APIRouter, Depends, Request

from ..auth import require_user
from ..models import StateSnapshot, UserSnapshot


router = APIRouter(prefix="/api")


@router.get("/state", response_model=StateSnapshot)
async def get_state(request: Request, user: UserSnapshot = Depends(require_user)) -> StateSnapshot:
    return await request.app.state.runtime.get_snapshot()


def create_router() -> APIRouter:
    """Compatibility factory retained for callers that assemble routers explicitly."""

    return router
