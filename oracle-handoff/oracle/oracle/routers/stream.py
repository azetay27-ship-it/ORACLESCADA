"""Authenticated complete-state Server-Sent Events stream."""

from __future__ import annotations

import asyncio
import json
from typing import Any, AsyncIterator, Dict

from fastapi import APIRouter, Request
from fastapi.responses import StreamingResponse

from ..auth import get_session_token, require_user
from ..models import OracleAPIError, UserSnapshot, model_dump, utc_iso


router = APIRouter(prefix="/api")


def _sse(event: str, data: Dict[str, Any], event_id: int | None = None) -> str:
    lines = []
    if event_id is not None:
        lines.append(f"id: {event_id}")
    lines.append(f"event: {event}")
    payload = json.dumps(data, ensure_ascii=False, separators=(",", ":"))
    lines.extend(f"data: {line}" for line in payload.splitlines() or [""])
    return "\n".join(lines) + "\n\n"


async def _events(request: Request, token: str) -> AsyncIterator[str]:
    runtime = request.app.state.runtime
    auth = request.app.state.auth
    settings = request.app.state.settings
    async with runtime.broadcaster.subscription() as queue:
        initial = model_dump(await runtime.get_snapshot())
        yield _sse("state", initial, int(initial["stateVersion"]))
        while True:
            if not await auth.is_valid(token):
                yield _sse("error", {"code": "SESSION_EXPIRED", "message": "Session expired; please log in again."})
                return
            try:
                snapshot = await asyncio.wait_for(queue.get(), timeout=settings.sse_heartbeat_seconds)
            except asyncio.TimeoutError:
                if not await auth.is_valid(token):
                    yield _sse("error", {"code": "SESSION_EXPIRED", "message": "Session expired; please log in again."})
                    return
                health = await runtime.health()
                yield _sse("heartbeat", {"stateVersion": health["stateVersion"], "time": utc_iso()})
                continue
            yield _sse("state", snapshot, int(snapshot.get("stateVersion", 0)))


@router.get("/stream")
async def stream(request: Request) -> StreamingResponse:
    # Authenticate before opening the stream; the generator rechecks the
    # opaque cookie session on every heartbeat and closes after logout/expiry.
    user: UserSnapshot = await require_user(request)
    token = get_session_token(request)
    if not token:
        raise OracleAPIError(401, "AUTHENTICATION_REQUIRED", "A valid Oracle session is required.")
    return StreamingResponse(
        _events(request, token),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",
        },
    )
