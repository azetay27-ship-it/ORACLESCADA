"""Authentication and current-user routes."""

from __future__ import annotations

from fastapi import APIRouter, Request, Response, status

from ..auth import ensure_same_origin, get_session_token, require_session, session_expiry
from ..models import LoginRequest, LoginResponse, MeResponse, OracleAPIError, utc_iso


router = APIRouter(prefix="/api")


@router.post("/auth/login", response_model=LoginResponse)
async def login(payload: LoginRequest, request: Request, response: Response) -> LoginResponse:
    result = await request.app.state.auth.authenticate(payload)
    if result is None:
        raise OracleAPIError(401, "INVALID_CREDENTIALS", "Username or password is incorrect.", error="Authentication failed")
    token, user, expires_at = result
    settings = request.app.state.settings
    response.set_cookie(
        key=settings.session_cookie,
        value=token,
        max_age=settings.session_ttl_seconds,
        expires=expires_at,
        httponly=True,
        secure=settings.cookie_secure,
        samesite="lax",
        path="/",
    )
    return LoginResponse(user=user, expires_at=utc_iso(expires_at))


@router.post("/auth/logout", status_code=status.HTTP_200_OK)
async def logout(request: Request, response: Response) -> dict[str, bool]:
    ensure_same_origin(request)
    token = get_session_token(request)
    await request.app.state.auth.logout(token)
    response.delete_cookie(key=request.app.state.settings.session_cookie, path="/")
    return {"ok": True}


@router.get("/me", response_model=MeResponse)
async def me(request: Request) -> MeResponse:
    # The session lookup also returns the expiry used by the browser to show
    # session state without exposing the opaque cookie token.
    current = await require_session(request)
    return MeResponse(user=current.user, expires_at=session_expiry(current))
