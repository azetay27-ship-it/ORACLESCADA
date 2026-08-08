from __future__ import annotations

import ast
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "oracle"


@pytest.mark.guardrail
def test_oracle_source_does_not_import_physical_io_adapters() -> None:
    files = list(SOURCE.rglob("*.py")) if SOURCE.exists() else []
    if not files:
        pytest.skip("Oracle source has not landed yet; physical-I/O scan will run once oracle/*.py exists.")

    banned_roots = {
        "asyncua",
        "minimalmodbus",
        "modbus_tk",
        "opcua",
        "pymodbus",
        "pycomm3",
        "serial",
        "snap7",
    }
    violations: list[str] = []
    for path in files:
        tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                names = [alias.name for alias in node.names]
            elif isinstance(node, ast.ImportFrom):
                names = [node.module or ""]
            else:
                continue
            for name in names:
                if name.split(".", 1)[0].lower() in banned_roots:
                    violations.append(f"{path.relative_to(ROOT)}:{getattr(node, 'lineno', '?')}: {name}")
    assert not violations, "Simulation-only Oracle must not import physical I/O adapters:\n" + "\n".join(violations)


@pytest.mark.contract
@pytest.mark.asyncio
async def test_runtime_identifies_simulation_mode(api_client, credentials) -> None:
    from helpers import login, state

    await login(api_client, credentials)
    snapshot = await state(api_client)
    system = snapshot["system"]
    assert system.get("simulation") is True
    assert "SIMULATED" in str(system.get("plc", "")).upper()
