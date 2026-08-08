from __future__ import annotations

import tomllib
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[1]


@pytest.mark.guardrail
def test_pyproject_declares_runtime_and_test_dependencies() -> None:
    data = tomllib.loads((ROOT / "pyproject.toml").read_text(encoding="utf-8"))
    project = data["project"]
    assert project["name"] == "oracle-nilit-scada"
    assert project["requires-python"] == ">=3.12"
    dependencies = " ".join(project["dependencies"]).lower()
    assert "fastapi" in dependencies
    assert "uvicorn" in dependencies
    assert "pydantic" in dependencies
    test_dependencies = " ".join(project["optional-dependencies"]["test"]).lower()
    for package in ("pytest", "pytest-asyncio", "httpx", "asgi-lifespan"):
        assert package in test_dependencies


@pytest.mark.guardrail
def test_dockerfile_is_slim_non_root_and_health_checked() -> None:
    dockerfile = (ROOT / "Dockerfile").read_text(encoding="utf-8")
    assert "python:3.12-slim" in dockerfile
    assert "USER oracle" in dockerfile
    assert "HEALTHCHECK" in dockerfile
    assert "oracle.app:app" in dockerfile
    assert "0.0.0.0" in dockerfile
    assert "8080" in dockerfile


@pytest.mark.guardrail
def test_compose_uses_restricted_service_defaults() -> None:
    compose = (ROOT / "compose.yaml").read_text(encoding="utf-8")
    assert "oracle:" in compose
    assert "${ORACLE_BIND_PORT:-8080}:8080" in compose
    assert "read_only: true" in compose
    assert "no-new-privileges:true" in compose
    assert "cap_drop:" in compose
    assert "- ALL" in compose
    assert "healthcheck:" in compose
    assert "ORACLE_OPERATOR_PASSWORD" in compose
    assert "ORACLE_SUPERVISOR_PASSWORD" in compose


@pytest.mark.guardrail
def test_dockerignore_excludes_local_artifacts() -> None:
    ignore = (ROOT / ".dockerignore").read_text(encoding="utf-8")
    for entry in (".git", ".venv", "__pycache__", ".pytest_cache", "tests"):
        assert entry in ignore
