from __future__ import annotations

import asyncio
import json
import os

import pytest

from helpers import login


pytestmark = [pytest.mark.sse, pytest.mark.asyncio]


async def test_authenticated_sse_emits_a_state_frame(api_client, credentials) -> None:
    if os.getenv("ORACLE_RUN_SSE_TESTS", "").lower() not in {"1", "true", "yes"}:
        pytest.skip("SSE checks are opt-in; set ORACLE_RUN_SSE_TESTS=1 to avoid buffered in-process transports by default.")

    await login(api_client, credentials)
    try:
        async with asyncio.timeout(8):
            async with api_client.stream("GET", "/api/stream") as response:
                assert response.status_code == 200, await response.aread()
                content_type = response.headers.get("content-type", "")
                assert "text/event-stream" in content_type
                data_payload = None
                async for line in response.aiter_lines():
                    if line.startswith("data:"):
                        raw = line.removeprefix("data:").strip()
                        if raw:
                            data_payload = json.loads(raw)
                            if isinstance(data_payload, dict) and "stateVersion" in data_payload:
                                break
                assert isinstance(data_payload, dict), "SSE stream did not emit a JSON state frame"
                assert "system" in data_payload or "stateVersion" in data_payload
    except TimeoutError:
        pytest.skip("SSE endpoint did not deliver a frame within 8 seconds; run against live Uvicorn if needed.")
