"""Authenticated screen-editor and published-screen routes."""

from __future__ import annotations

from typing import Any

from fastapi import APIRouter, Depends, Header, Request

from ..auth import require_user
from ..models import OracleAPIError, UserSnapshot
from ..screen_store import ScreenConflict, ScreenNotFound, ScreenStoreError


router = APIRouter(prefix="/api")


def _store(request: Request):
    return request.app.state.screens


def _revision(header: str | None, body: Any = None) -> int | None:
    value = header
    if value is None and isinstance(body, dict):
        value = body.get("expectedRevision")
    if value is None or value == "":
        return None
    try:
        return int(str(value).strip().strip('"'))
    except ValueError as exc:
        raise OracleAPIError(422, "INVALID_REVISION", "If-Match must contain a numeric screen revision.") from exc


def _supervisor(user: UserSnapshot) -> None:
    if user.role != "supervisor":
        raise OracleAPIError(403, "SUPERVISOR_REQUIRED", "Supervisor permission is required for screen authoring.")


def _handle(error: Exception) -> None:
    if isinstance(error, ScreenNotFound):
        raise OracleAPIError(404, "SCREEN_NOT_FOUND", f"Screen {error.args[0]} was not found.")
    if isinstance(error, ScreenConflict):
        raise OracleAPIError(409, "SCREEN_REVISION_CONFLICT", str(error))
    if isinstance(error, ScreenStoreError):
        raise OracleAPIError(422, "SCREEN_INVALID", str(error))
    raise error


@router.get("/screens")
async def list_screens(request: Request, user: UserSnapshot = Depends(require_user)) -> dict[str, Any]:
    screens = _store(request).list()
    if user.role != "supervisor":
        screens = [item for item in screens if item.get("status") == "published"]
    return {"screens": screens}


@router.post("/screens")
async def create_screen(payload: dict[str, Any], request: Request, user: UserSnapshot = Depends(require_user)) -> dict[str, Any]:
    _supervisor(user)
    try:
        return _store(request).create(payload, user=user.username)
    except Exception as error:
        _handle(error)
        raise AssertionError("unreachable")


@router.get("/screens/{screen_id}")
async def get_screen(screen_id: str, request: Request, user: UserSnapshot = Depends(require_user)) -> dict[str, Any]:
    try:
        document = _store(request).get(screen_id)
    except Exception as error:
        _handle(error)
        raise AssertionError("unreachable")
    if user.role != "supervisor" and document.get("status") != "published":
        raise OracleAPIError(403, "PUBLISHED_SCREEN_REQUIRED", "Operators can only view published screens.")
    return document


@router.put("/screens/{screen_id}")
async def save_screen(screen_id: str, payload: dict[str, Any], request: Request, user: UserSnapshot = Depends(require_user), if_match: str | None = Header(default=None, alias="If-Match")) -> dict[str, Any]:
    _supervisor(user)
    document = {**payload, "id": screen_id}
    try:
        return _store(request).save(document, user=user.username, expected_revision=_revision(if_match, payload))
    except Exception as error:
        _handle(error)
        raise AssertionError("unreachable")


@router.post("/screens/{screen_id}/duplicate")
async def duplicate_screen(screen_id: str, request: Request, user: UserSnapshot = Depends(require_user), payload: dict[str, Any] | None = None) -> dict[str, Any]:
    _supervisor(user)
    try:
        return _store(request).duplicate(screen_id, user=user.username, new_id=(payload or {}).get("id"))
    except Exception as error:
        _handle(error)
        raise AssertionError("unreachable")


@router.post("/screens/{screen_id}/validate")
async def validate_screen(screen_id: str, request: Request, payload: dict[str, Any] | None = None, user: UserSnapshot = Depends(require_user)) -> dict[str, Any]:
    try:
        document = payload or _store(request).get(screen_id)
        return _store(request).validate(document)
    except Exception as error:
        _handle(error)
        raise AssertionError("unreachable")


@router.post("/screens/{screen_id}/publish")
async def publish_screen(screen_id: str, request: Request, payload: dict[str, Any] | None = None, user: UserSnapshot = Depends(require_user), if_match: str | None = Header(default=None, alias="If-Match")) -> dict[str, Any]:
    _supervisor(user)
    try:
        expected = _revision(if_match, payload)
        if payload and "elements" in payload:
            document = {**payload, "id": screen_id}
            saved = _store(request).save(document, user=user.username, expected_revision=expected)
            expected = int(saved.get("revision", 1))
        return _store(request).publish(screen_id, user=user.username, expected_revision=expected)
    except Exception as error:
        _handle(error)
        raise AssertionError("unreachable")


@router.get("/editor/parts")
async def editor_parts(request: Request, user: UserSnapshot = Depends(require_user)) -> dict[str, Any]:
    return {"parts": _store(request).parts()}


@router.get("/editor/templates")
async def editor_templates(request: Request, user: UserSnapshot = Depends(require_user)) -> dict[str, Any]:
    return {"templates": _store(request).templates()}


@router.get("/editor/tag-catalog")
async def editor_tag_catalog(request: Request, user: UserSnapshot = Depends(require_user)) -> dict[str, Any]:
    return {"tags": _store(request).tag_catalog() if hasattr(_store(request), "tag_catalog") else []}


@router.get("/editor/capabilities")
async def editor_capabilities(request: Request, user: UserSnapshot = Depends(require_user)) -> dict[str, Any]:
    return {"capabilities": _store(request).capabilities()}
