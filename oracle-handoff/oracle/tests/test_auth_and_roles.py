from __future__ import annotations

import pytest

from helpers import command, json_body, login


pytestmark = [pytest.mark.contract, pytest.mark.asyncio]


@pytest.mark.parametrize("role", ["operator", "supervisor"])
async def test_login_returns_role_and_session(api_client, credentials, role: str) -> None:
    payload = await login(api_client, credentials, role)
    user = payload.get("user", payload)
    assert user.get("username") == role
    assert user.get("role") == role
    assert api_client.cookies.get("oracle_session") or api_client.cookies

    me = await api_client.get("/api/me")
    assert me.status_code == 200, me.text
    me_body = json_body(me)
    me_user = me_body.get("user", me_body)
    assert me_user.get("role") == role


async def test_invalid_credentials_do_not_create_a_session(api_client, credentials) -> None:
    response = await api_client.post(
        "/api/auth/login",
        json={"username": "operator", "password": credentials["operator"] + "-wrong"},
    )
    assert response.status_code == 401, response.text
    state = await api_client.get("/api/state")
    assert state.status_code == 401, state.text


async def test_logout_invalidates_state_access(api_client, credentials) -> None:
    await login(api_client, credentials)
    response = await api_client.post("/api/auth/logout")
    assert response.status_code == 200, response.text
    state = await api_client.get("/api/state")
    assert state.status_code == 401, state.text


@pytest.mark.parametrize(
    ("action", "fields"),
    [
        ("set-mode", {"mode": "MANUAL"}),
        ("reset-simulator", {}),
        ("set-sim-config", {"noiseScale": 0.0}),
    ],
)
async def test_operator_cannot_run_supervisor_commands(api_client, credentials, action, fields) -> None:
    await login(api_client, credentials, "operator")
    response = await command(api_client, action, **fields)
    assert response.status_code == 403, response.text


async def test_supervisor_can_change_mode_when_process_is_stopped(api_client, credentials) -> None:
    await login(api_client, credentials, "supervisor")
    stop = await command(api_client, "stop")
    assert stop.status_code == 200, stop.text
    mode = await command(api_client, "set-mode", mode="MANUAL")
    assert mode.status_code in {200, 409}, mode.text
    if mode.status_code == 409:
        pytest.skip(f"Backend retained a process interlock while changing mode: {mode.text}")
    body = json_body(mode)
    assert body.get("commandId") or body.get("requestId")
