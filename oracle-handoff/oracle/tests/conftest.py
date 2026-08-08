"""Shared fixtures for the Oracle contract suite.

The backend workstream can land independently of this packaging workstream. The
fixtures therefore discover the FastAPI app lazily and skip backend tests with
an actionable message until the app is importable.
"""

from __future__ import annotations

import importlib
import inspect
import os
from collections.abc import AsyncIterator
from typing import Any

import pytest

try:
    import httpx
except ImportError:  # pragma: no cover - exercised by environments without test extras
    httpx = None  # type: ignore[assignment]

try:
    from asgi_lifespan import LifespanManager
except ImportError:  # pragma: no cover - exercised by environments without test extras
    LifespanManager = None  # type: ignore[assignment,misc]

try:
    import pytest_asyncio
except ImportError:  # pragma: no cover - pytest itself will explain the missing extra
    pytest_asyncio = None  # type: ignore[assignment]


DEFAULT_APP_TARGETS = (
    "oracle.app:app",
    "oracle.main:app",
    "oracle.app:create_app",
    "oracle.main:create_app",
    "main:app",
)


def _targets() -> tuple[str, ...]:
    override = os.getenv("ORACLE_APP_IMPORT")
    return (override,) if override else DEFAULT_APP_TARGETS


def _load_target(target: str) -> Any:
    if ":" not in target:
        raise ValueError(f"ORACLE_APP_IMPORT must use module:attribute syntax, got {target!r}")
    module_name, attribute_name = target.split(":", 1)
    module = importlib.import_module(module_name)
    return getattr(module, attribute_name)


def _build_app(factory_or_app: Any) -> Any:
    if not callable(factory_or_app) or hasattr(factory_or_app, "routes"):
        return factory_or_app

    # Prefer a test-aware factory when one is provided, but support the simple
    # no-argument factory used by the approved FastAPI plan.
    for kwargs in ({"testing": True}, {}):
        try:
            candidate = factory_or_app(**kwargs)
        except TypeError:
            continue
        if inspect.isawaitable(candidate):
            raise TypeError("Oracle app factory returned an awaitable; expose a synchronous test factory")
        return candidate
    raise TypeError("Oracle app factory could not be called with testing=True or no arguments")


@pytest.fixture(scope="function")
def oracle_app() -> Any:
    """Return the app, or skip cleanly while the backend workstream is absent."""

    if httpx is None:
        pytest.skip("Install the [test] extra to run FastAPI contract tests (httpx is unavailable).")
    if LifespanManager is None:
        pytest.skip("Install the [test] extra to run FastAPI contract tests (asgi-lifespan is unavailable).")

    missing_module = True
    errors: list[str] = []
    for target in _targets():
        try:
            loaded = _load_target(target)
            missing_module = False
            return _build_app(loaded)
        except ModuleNotFoundError as exc:
            # A missing candidate module means the backend has not landed yet.
            # A missing dependency from an existing module is a real setup error.
            if exc.name and (exc.name == target.split(":", 1)[0] or exc.name.startswith("oracle.")):
                errors.append(f"{target}: module not found")
                continue
            raise
        except AttributeError:
            errors.append(f"{target}: attribute not found")
        except Exception as exc:  # pragma: no cover - backend-specific startup failures
            raise AssertionError(f"Oracle app target {target!r} failed to load: {exc}") from exc

    if missing_module:
        pytest.skip(
            "Oracle backend not found. Expected FastAPI app at one of: "
            + ", ".join(_targets())
            + ". Backend-facing tests are ready and will activate when source lands."
        )
    pytest.fail("No usable Oracle FastAPI app target found: " + "; ".join(errors))


@pytest_asyncio.fixture  # type: ignore[union-attr]
async def api_client(oracle_app: Any) -> AsyncIterator[Any]:
    """Run one isolated ASGI lifespan and expose an httpx async client."""

    assert httpx is not None
    assert LifespanManager is not None
    transport = httpx.ASGITransport(app=oracle_app, raise_app_exceptions=True)
    async with LifespanManager(oracle_app):
        async with httpx.AsyncClient(transport=transport, base_url="http://oracle.test") as client:
            yield client


@pytest.fixture
def credentials() -> dict[str, str]:
    return {
        "operator": os.getenv("ORACLE_OPERATOR_PASSWORD", "operator"),
        "supervisor": os.getenv("ORACLE_SUPERVISOR_PASSWORD", "supervisor"),
    }
