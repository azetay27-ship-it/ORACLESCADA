"""Small protocol helpers shared by contract tests."""

from __future__ import annotations

import asyncio
import json
import uuid
from collections.abc import Callable
from typing import Any


def command_id() -> str:
    return f"test-{uuid.uuid4()}"


def json_body(response: Any) -> dict[str, Any]:
    try:
        body = response.json()
    except (ValueError, json.JSONDecodeError) as exc:
        raise AssertionError(f"Expected JSON response, got {response.text[:500]!r}") from exc
    assert isinstance(body, dict), f"Expected JSON object, got {type(body).__name__}"
    return body


async def login(client: Any, credentials: dict[str, str], role: str = "operator") -> dict[str, Any]:
    response = await client.post(
        "/api/auth/login",
        json={"username": role, "password": credentials[role]},
    )
    assert response.status_code == 200, f"Login failed: {response.status_code} {response.text}"
    return json_body(response)


async def state(client: Any) -> dict[str, Any]:
    response = await client.get("/api/state")
    assert response.status_code == 200, f"State request failed: {response.status_code} {response.text}"
    return json_body(response)


async def command(client: Any, action: str, **fields: Any) -> Any:
    payload = {"action": action, "clientCommandId": command_id(), **fields}
    return await client.post("/api/commands", json=payload)


def accepted(result: dict[str, Any]) -> bool:
    value = result.get("accepted")
    if isinstance(value, bool):
        return value
    return str(result.get("status", "")).upper() in {"ACCEPTED", "NOOP"}


def rejected(result: dict[str, Any]) -> bool:
    value = result.get("accepted")
    if isinstance(value, bool):
        return not value
    return str(result.get("status", "")).upper() in {"REJECTED", "FAILED"}


async def wait_for_state(client: Any, predicate: Callable[[dict[str, Any]], bool], timeout: float = 5.0) -> dict[str, Any]:
    deadline = asyncio.get_running_loop().time() + timeout
    latest = await state(client)
    while not predicate(latest):
        if asyncio.get_running_loop().time() >= deadline:
            raise AssertionError(f"State did not reach expected condition before timeout: {latest}")
        await asyncio.sleep(0.1)
        latest = await state(client)
    return latest


def tag_value(snapshot: dict[str, Any], *keys: str) -> Any:
    tags = snapshot.get("tags", {})
    for key in keys:
        if key in tags:
            value = tags[key]
            return value.get("value") if isinstance(value, dict) else value
    raise KeyError(f"None of the expected tag keys were found: {keys}")
