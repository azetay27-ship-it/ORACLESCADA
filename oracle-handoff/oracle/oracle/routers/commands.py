"""Authenticated command execution routes."""

from __future__ import annotations

from fastapi import APIRouter, Depends, Request

from ..auth import ensure_same_origin, require_user
from ..models import CommandRequest, CommandResult, OracleAPIError, UserSnapshot, model_dump


router = APIRouter(prefix="/api")


def _status_for_rejection(code: str | None) -> int:
    if code in {"SUPERVISOR_REQUIRED", "UNAUTHORIZED"}:
        return 403
    if code in {"UNSUPPORTED_ACTION", "UNSUPPORTED_COMMAND", "MODE_REQUIRED", "NOISE_SCALE_REQUIRED", "INVALID_COMMAND", "INVALID_PARAMETER"}:
        return 422
    if code in {"STATE_VERSION_CONFLICT"}:
        return 409
    return 409


async def _execute(request: Request, payload: CommandRequest, user: UserSnapshot) -> CommandResult:
    ensure_same_origin(request)
    result = await request.app.state.runtime.execute_command(payload, user)
    if not result.accepted:
        details = model_dump(result)
        raise OracleAPIError(
            _status_for_rejection(result.reason_code),
            result.reason_code or "COMMAND_REJECTED",
            result.message,
            error="Command rejected",
            details=details,
        )
    return result


@router.post("/commands", response_model=CommandResult)
async def commands(payload: CommandRequest, request: Request, user: UserSnapshot = Depends(require_user)) -> CommandResult:
    return await _execute(request, payload, user)


@router.post("/command", response_model=CommandResult)
async def legacy_command(payload: CommandRequest, request: Request, user: UserSnapshot = Depends(require_user)) -> CommandResult:
    """Temporary compatibility alias for the original single-command route."""

    return await _execute(request, payload, user)
