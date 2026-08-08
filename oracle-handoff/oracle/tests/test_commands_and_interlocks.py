from __future__ import annotations

import pytest

from helpers import accepted, command, json_body, login, rejected, state, tag_value, wait_for_state


pytestmark = [pytest.mark.contract, pytest.mark.asyncio]


async def test_start_is_rejected_when_inlet_is_closed(api_client, credentials) -> None:
    await login(api_client, credentials)
    await command(api_client, "stop")
    await wait_for_state(api_client, lambda snapshot: not bool(tag_value(snapshot, "P-101.run")))

    close = await command(api_client, "close-inlet")
    assert close.status_code == 200, close.text
    assert accepted(json_body(close)), close.text

    start = await command(api_client, "start")
    assert start.status_code in {200, 409}, start.text
    result = json_body(start)
    assert rejected(result), f"Pump start unexpectedly accepted with closed inlet: {result}"
    reason = " ".join(str(result.get(key, "")) for key in ("reasonCode", "code", "reason", "message"))
    assert any(token in reason.upper() for token in ("INLET", "PERMISSIVE", "CLOSED")), result


async def test_inlet_cannot_close_while_pump_is_running(api_client, credentials) -> None:
    await login(api_client, credentials)
    await command(api_client, "open-inlet")

    current = await state(api_client)
    if not bool(tag_value(current, "P-101.run")):
        start = await command(api_client, "start")
        if start.status_code != 200 or not accepted(json_body(start)):
            pytest.skip(
                "The backend exposes additional start permissives beyond the basic interface; "
                f"it did not start in this fixture state: {start.text}"
            )
        current = await wait_for_state(api_client, lambda snapshot: bool(tag_value(snapshot, "P-101.run")))

    assert bool(tag_value(current, "P-101.run"))
    close = await command(api_client, "close-inlet")
    assert close.status_code in {200, 409}, close.text
    result = json_body(close)
    assert rejected(result), f"Inlet close unexpectedly accepted while pump runs: {result}"
    reason = " ".join(str(result.get(key, "")) for key in ("reasonCode", "code", "reason", "message"))
    assert any(token in reason.upper() for token in ("PUMP", "RUNNING", "INTERLOCK")), result

    await command(api_client, "stop")


async def test_stop_is_available_and_idempotent(api_client, credentials) -> None:
    await login(api_client, credentials)
    first = await command(api_client, "stop")
    second = await command(api_client, "stop")
    assert first.status_code == 200, first.text
    assert second.status_code == 200, second.text
    assert accepted(json_body(first))
    assert accepted(json_body(second))
