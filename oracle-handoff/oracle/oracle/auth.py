"""Local, in-memory authentication and role authorization."""

from __future__ import annotations

import asyncio
import hashlib
import hmac
import secrets
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Dict, Optional, Tuple
from urllib.parse import urlsplit

from fastapi import Request

from .models import LoginRequest, UserSnapshot, utc_iso, utc_now
from .settings import Settings


@dataclass(frozen=True)
class Session:
    token: str
    user: UserSnapshot
    created_at: datetime
    expires_at: datetime


class SessionStore:
    """Opaque-cookie sessions held only in process memory."""

    def __init__(self, settings: Settings) -> None:
        self.settings = settings
        self._sessions: Dict[str, Session] = {}
        self._lock = asyncio.Lock()
        self._password_digests = {
            "operator": self._digest(settings.operator_password),
            "supervisor": self._digest(settings.supervisor_password),
        }
        self._users = {
            "operator": UserSnapshot(
                id="user-operator",
                username="operator",
                display_name="Operator",
                role="operator",
            ),
            "supervisor": UserSnapshot(
                id="user-supervisor",
                username="supervisor",
                display_name="Supervisor",
                role="supervisor",
            ),
        }

    @staticmethod
    def _digest(value: str) -> bytes:
        return hashlib.sha256(value.encode("utf-8")).digest()

    async def authenticate(self, credentials: LoginRequest) -> Optional[Tuple[str, UserSnapshot, datetime]]:
        username = credentials.username.strip().lower()
        if username not in self._users:
            # Run the same comparison path for unknown users to avoid a simple
            # timing distinction between valid and invalid usernames.
            hmac.compare_digest(self._digest(credentials.password), self._digest("invalid"))
            return None
        supplied = self._digest(credentials.password)
        if not hmac.compare_digest(supplied, self._password_digests[username]):
            return None

        now = utc_now()
        expires_at = now + timedelta(seconds=self.settings.session_ttl_seconds)
        token = secrets.token_urlsafe(32)
        session = Session(token=token, user=self._users[username], created_at=now, expires_at=expires_at)
        async with self._lock:
            self._sessions[token] = session
            self._purge_expired_locked(now)
        return token, session.user, expires_at

    async def get_session(self, token: Optional[str]) -> Optional[Session]:
        if not token:
            return None
        now = utc_now()
        async with self._lock:
            session = self._sessions.get(token)
            if session is None:
                return None
            if session.expires_at <= now:
                self._sessions.pop(token, None)
                return None
            return session

    async def get_user(self, token: Optional[str]) -> Optional[UserSnapshot]:
        session = await self.get_session(token)
        return session.user if session else None

    async def is_valid(self, token: Optional[str]) -> bool:
        return await self.get_session(token) is not None

    async def logout(self, token: Optional[str]) -> None:
        if not token:
            return
        async with self._lock:
            self._sessions.pop(token, None)

    async def clear(self) -> None:
        async with self._lock:
            self._sessions.clear()

    def _purge_expired_locked(self, now: datetime) -> None:
        expired = [token for token, session in self._sessions.items() if session.expires_at <= now]
        for token in expired:
            self._sessions.pop(token, None)


def get_session_token(request: Request) -> Optional[str]:
    settings: Settings = request.app.state.settings
    return request.cookies.get(settings.session_cookie)


async def require_user(request: Request) -> UserSnapshot:
    """FastAPI dependency for all authenticated API routes."""

    from .models import OracleAPIError

    token = get_session_token(request)
    user = await request.app.state.auth.get_user(token)
    if user is None:
        raise OracleAPIError(401, "AUTHENTICATION_REQUIRED", "A valid Oracle session is required.")
    return user


async def require_session(request: Request) -> Session:
    from .models import OracleAPIError

    token = get_session_token(request)
    session = await request.app.state.auth.get_session(token)
    if session is None:
        raise OracleAPIError(401, "AUTHENTICATION_REQUIRED", "A valid Oracle session is required.")
    return session


def session_expiry(session: Session) -> str:
    return utc_iso(session.expires_at)


def ensure_same_origin(request: Request) -> None:
    """Reject cross-origin state changes when a browser supplies Origin."""

    from .models import OracleAPIError

    origin = request.headers.get("origin")
    if not origin:
        return
    parsed = urlsplit(origin)
    expected_host = request.headers.get("host", "")
    expected = f"{request.url.scheme}://{expected_host}".rstrip("/")
    actual = f"{parsed.scheme}://{parsed.netloc}".rstrip("/")
    if actual != expected:
        raise OracleAPIError(403, "ORIGIN_NOT_ALLOWED", "State-changing requests must originate from the Oracle host.")
