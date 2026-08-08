from __future__ import annotations

import pytest

from helpers import login, state


pytestmark = [pytest.mark.contract, pytest.mark.asyncio]


REQUIRED_TAGS = {
    "TK-101.level",
    "TK-102.level",
    "FT-101.flow",
    "PT-101.pressure",
    "AIT-101.ph",
    "TT-101.temperature",
    "P-101.run",
    "XV-101.open",
}


async def test_state_has_versioned_oracle_nilit_schema(api_client, credentials) -> None:
    await login(api_client, credentials)
    snapshot = await state(api_client)
    for key in ("schemaVersion", "stateVersion", "system", "tags", "alarms", "events"):
        assert key in snapshot, f"Missing state field {key!r}: {snapshot}"

    system = snapshot["system"]
    assert system.get("name") == "Oracle"
    assert system.get("site") == "NILIT"
    assert system.get("simulation") is True
    assert "scanMs" in system
    assert "updatedAt" in system
    assert "plc" in system
    assert "SIMULATED" in str(system["plc"]).upper()

    tags = snapshot["tags"]
    assert REQUIRED_TAGS.issubset(tags), f"Missing required tags: {REQUIRED_TAGS - set(tags)}"
    for key in REQUIRED_TAGS:
        tag = tags[key]
        assert "value" in tag
        assert "quality" in tag
        assert "history" in tag
        assert len(tag["history"]) <= 90


async def test_state_version_is_monotonic(api_client, credentials) -> None:
    await login(api_client, credentials)
    first = await state(api_client)
    second = await state(api_client)
    assert isinstance(first["stateVersion"], int)
    assert isinstance(second["stateVersion"], int)
    assert second["stateVersion"] >= first["stateVersion"]


async def test_health_is_public_and_reports_simulation(api_client) -> None:
    health = await api_client.get("/health")
    assert health.status_code == 200, health.text
    body = health.json()
    assert body.get("ok") is True
    assert body.get("service") == "oracle"
    assert body.get("connected") is True
    assert "SIMULATED" in str(body.get("plc", "")).upper()
