from __future__ import annotations

import pytest

from helpers import accepted, command, json_body, login, state


pytestmark = [pytest.mark.contract, pytest.mark.asyncio]


async def test_ack_all_is_safe_when_no_alarms_are_active(api_client, credentials) -> None:
    await login(api_client, credentials)
    before = await state(api_client)
    response = await command(api_client, "ack-all")
    assert response.status_code == 200, response.text
    assert accepted(json_body(response)), response.text

    after = await state(api_client)
    active_before = {alarm["id"] for alarm in before["alarms"] if alarm.get("active")}
    active_after = {alarm["id"] for alarm in after["alarms"] if alarm.get("active")}
    assert active_before.issubset(active_after)


async def test_acknowledgement_does_not_clear_active_alarm(api_client, credentials) -> None:
    await login(api_client, credentials)
    before = await state(api_client)
    active = [alarm for alarm in before["alarms"] if alarm.get("active")]
    if not active:
        pytest.skip("No active alarm is present in the deterministic starting state; lifecycle activation needs a fault fixture.")

    response = await command(api_client, "ack-all")
    assert response.status_code == 200, response.text
    after = await state(api_client)
    by_id = {alarm["id"]: alarm for alarm in after["alarms"]}
    for alarm in active:
        current = by_id[alarm["id"]]
        assert current.get("active") is True
        assert current.get("acknowledged") is True
        assert current.get("since") == alarm.get("since")


async def test_alarm_records_expose_lifecycle_fields(api_client, credentials) -> None:
    await login(api_client, credentials)
    snapshot = await state(api_client)
    for alarm in snapshot["alarms"]:
        for field in ("id", "source", "message", "severity", "active", "acknowledged", "since"):
            assert field in alarm, f"Alarm {alarm!r} lacks lifecycle field {field!r}"
