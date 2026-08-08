"""Environment-backed Oracle configuration."""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


def _bool(name: str, default: bool) -> bool:
    value = os.getenv(name)
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


def _int(name: str, default: int, minimum: int = 0) -> int:
    value = os.getenv(name)
    if value is None:
        return default
    try:
        return max(minimum, int(value))
    except ValueError:
        return default


def _float(name: str, default: float, minimum: float = 0.0) -> float:
    value = os.getenv(name)
    if value is None:
        return default
    try:
        return max(minimum, float(value))
    except ValueError:
        return default


@dataclass(frozen=True)
class Settings:
    """Runtime settings.

    The built-in passwords are development-only conveniences.  A deployment
    must set ``ORACLE_OPERATOR_PASSWORD`` and ``ORACLE_SUPERVISOR_PASSWORD``
    through its secret mechanism before exposing Oracle to a network.
    """

    service_name: str = "oracle"
    host: str = "0.0.0.0"
    port: int = 8080
    operator_password: str = "operator"
    supervisor_password: str = "supervisor"
    session_ttl_seconds: int = 28_800
    cookie_name: str = "oracle_session"
    # ``session_cookie`` is the backend's stable internal spelling.
    session_cookie: str = "oracle_session"
    cookie_secure: bool = False
    cookie_samesite: str = "lax"
    scan_interval_seconds: float = 1.0
    heartbeat_seconds: int = 15
    max_history: int = 90
    max_events: int = 100
    sse_queue_size: int = 8
    sse_heartbeat_seconds: int = 15
    stale_after_seconds: float = 5.0
    simulator_noise_scale: float = 0.0
    history_size: int = 90
    event_history_size: int = 100
    public_dir: Path = Path(__file__).resolve().parent.parent / "public"
    screen_store: Path = Path.cwd() / "screen-data"

    @classmethod
    def from_env(cls) -> "Settings":
        return cls(
            service_name=os.getenv("ORACLE_SERVICE_NAME", "oracle"),
            host=os.getenv("ORACLE_HOST", "0.0.0.0"),
            port=_int("ORACLE_PORT", 8080, minimum=1),
            operator_password=os.getenv("ORACLE_OPERATOR_PASSWORD", "operator"),
            supervisor_password=os.getenv("ORACLE_SUPERVISOR_PASSWORD", "supervisor"),
            session_ttl_seconds=_int("ORACLE_SESSION_TTL_SECONDS", 28_800, minimum=60),
            cookie_name=os.getenv("ORACLE_COOKIE_NAME", "oracle_session"),
            session_cookie=os.getenv("ORACLE_COOKIE_NAME", "oracle_session"),
            cookie_secure=_bool("ORACLE_COOKIE_SECURE", False),
            cookie_samesite=os.getenv("ORACLE_COOKIE_SAMESITE", "lax"),
            scan_interval_seconds=_float("ORACLE_SCAN_INTERVAL_SECONDS", 1.0, minimum=0.05),
            heartbeat_seconds=_int("ORACLE_HEARTBEAT_SECONDS", 15, minimum=1),
            max_history=_int("ORACLE_MAX_HISTORY", 90, minimum=1),
            max_events=_int("ORACLE_MAX_EVENTS", 100, minimum=1),
            sse_queue_size=_int("ORACLE_SSE_QUEUE_SIZE", 8, minimum=1),
            sse_heartbeat_seconds=_int("ORACLE_HEARTBEAT_SECONDS", 15, minimum=1),
            stale_after_seconds=_float("ORACLE_STALE_AFTER_SECONDS", 5.0, minimum=1.0),
            simulator_noise_scale=_float("ORACLE_SIMULATOR_NOISE_SCALE", 0.0, minimum=0.0),
            history_size=_int("ORACLE_MAX_HISTORY", 90, minimum=1),
            event_history_size=_int("ORACLE_MAX_EVENTS", 100, minimum=1),
            public_dir=Path(os.getenv("ORACLE_PUBLIC_DIR", str(cls.public_dir))),
            screen_store=Path(os.getenv("ORACLE_SCREEN_STORE", str(Path.cwd() / "screen-data"))),
        )
