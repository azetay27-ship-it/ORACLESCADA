# Oracle — NILIT SCADA

Oracle is the main NILIT SCADA/HMI application. Version 1 is simulation-only: it provides a browser HMI, a FastAPI/Uvicorn service boundary, live state streaming, alarms, audit events, and safe command/interlock contracts without connecting to physical PLCs, OPC UA servers, Modbus devices, or plant equipment.

This directory contains the runtime packaging boundary and verification suite. The backend implementation is expected under `oracle/`, and the static HMI is expected under `public/`.

## Safety boundary

Do not connect this image to physical equipment. The v1 runtime must use a simulator adapter only. A future PLC/OPC UA adapter requires a separate integration, network, authorization, and formal process-safety review.

The default Compose credentials and session secret are development values. Set explicit secrets before any shared or production-like deployment, and keep Oracle on an appropriately isolated network.

## Run locally with Python

Python 3.12 or newer is required.

```powershell
cd C:\Users\itaya\Documents\Codex\2026-08-06\wr\outputs\oracle
py -3.12 -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install --upgrade pip
python -m pip install -e ".[test]"
python -m uvicorn oracle.app:app --host 127.0.0.1 --port 8080
```

Open <http://127.0.0.1:8080>. The health endpoint is public:

```powershell
Invoke-RestMethod http://127.0.0.1:8080/health
```

The documented development credentials are:

| Role | Username | Default password |
| --- | --- | --- |
| Operator | `operator` | `operator` |
| Supervisor | `supervisor` | `supervisor` |

Override them with `ORACLE_OPERATOR_PASSWORD` and `ORACLE_SUPERVISOR_PASSWORD` before starting the service. These defaults are for local simulation only.

## Run with Docker Compose

Docker Desktop with Compose support is required.

```powershell
cd C:\Users\itaya\Documents\Codex\2026-08-06\wr\outputs\oracle
$env:ORACLE_OPERATOR_PASSWORD = "change-operator-password"
$env:ORACLE_SUPERVISOR_PASSWORD = "change-supervisor-password"
$env:ORACLE_SESSION_SECRET = "replace-with-a-long-random-secret"
docker compose up --build -d
docker compose ps
Invoke-RestMethod http://127.0.0.1:8080/health
```

The service listens on port `8080` by default. Set `ORACLE_BIND_PORT` to expose another host port, for example `$env:ORACLE_BIND_PORT = "18080"`.

The container runs as a non-root user, drops Linux capabilities, uses a read-only root filesystem with a temporary `/tmp`, and reports health from `/health`. Stop it with:

```powershell
docker compose down
```

## Verification

Install the test dependencies and run the packaging checks plus API contract suite:

```powershell
python -m pip install -e ".[test]"
python -m pytest
```

The suite is deliberately contract-first. If the FastAPI backend is not present yet, backend-facing tests skip with a clear `Oracle backend not found` reason; packaging, documentation, and static simulation-guardrail tests still run. Once `oracle.app:app` (or a supported app factory) is available, the auth, state, command, interlock, alarm, health, and simulation tests exercise it through `httpx` and an ASGI lifespan.

Run focused checks:

```powershell
python -m pytest -m guardrail
python -m pytest -m contract
```

SSE tests are opt-in because in-process ASGI transports may buffer streaming responses:

```powershell
$env:ORACLE_RUN_SSE_TESTS = "1"
python -m pytest -m sse
```

For a true streaming check, start Oracle with Uvicorn and use a live HTTP client or browser smoke run; the included SSE test intentionally targets the ASGI app and remains opt-in because in-process transports can buffer streams.

### Optional browser smoke tests

Browser tests are skipped, rather than failing collection, when Playwright or a Chromium executable is unavailable:

```powershell
python -m pip install -e ".[test,browser]"
python -m playwright install chromium
$env:ORACLE_BROWSER_URL = "http://127.0.0.1:8080"
python -m pytest -m browser
```

The browser smoke test uses stable semantic selectors and checks login, Oracle/NILIT branding, authenticated HMI access, navigation, and logout. It does not issue physical control commands.

## Contract covered by the tests

The API tests target the approved v1 boundary:

- `POST /api/auth/login`
- `POST /api/auth/logout`
- `GET /api/me`
- `GET /api/state`
- `GET /api/stream`
- `POST /api/commands`
- compatibility alias `POST /api/command`
- `GET /health`

Expected command actions include `start`, `stop`, `open-inlet`, `close-inlet`, `set-mode`, `ack-all`, `reset-simulator`, and `set-sim-config`. The tests verify operator/supervisor authorization, session invalidation, state schema and versions, pump/valve interlocks, alarm acknowledgment without premature clearing, SSE framing where feasible, and a simulation-only implementation boundary.

## Expected state and command behavior

State responses should include `schemaVersion`, `stateVersion`, `system`, `tags`, `alarms`, and `events`. Tags should expose values, units, quality, limits, and bounded trend history. The system should identify itself as Oracle/NILIT and mark the PLC as simulated.

Commands should return an acceptance result with a command ID, action, state version, and a reason/code when rejected. A `409` is expected for a process interlock, `403` for a role violation, `401` for a missing/expired session, and `422` for invalid payloads.

The key safety cases are:

- Pump start is rejected with a closed inlet or insufficient tank level.
- The inlet cannot close while the pump is running.
- Stop remains available and repeated safe commands are idempotent.
- Acknowledging an alarm does not clear an active process condition.
- Supervisor-only mode/reset/configuration commands are not available to operators.

## Test environment variables

| Variable | Purpose | Default |
| --- | --- | --- |
| `ORACLE_OPERATOR_PASSWORD` | Operator credential used by tests/service | `operator` |
| `ORACLE_SUPERVISOR_PASSWORD` | Supervisor credential used by tests/service | `supervisor` |
| `ORACLE_SESSION_SECRET` | Session signing/entropy configuration | implementation-defined |
| `ORACLE_APP_IMPORT` | Override app import target, e.g. `oracle.app:app` | auto-discovery |
| `ORACLE_RUN_SSE_TESTS` | Enable opt-in SSE checks | unset/disabled |
| `ORACLE_BROWSER_URL` | Enable browser smoke tests against a live service | unset/skip |
| `ORACLE_SCREEN_STORE` | JSON draft/published screen storage path | `./screen-data` locally; `/tmp/oracle-screens` in Compose |

## Rollout, rollback, and troubleshooting

1. Build the image with `docker compose build`.
2. Start it with explicit development or environment-injected credentials.
3. Confirm `docker compose ps` reports `healthy` and verify `/health`.
4. Log in through the HMI and confirm the simulation banner, PLC simulated status, alarms, trends, and audit log.
5. Inspect logs with `docker compose logs --follow oracle`.
6. Roll back by stopping the current Compose stack and starting the previously tagged `oracle-nilit-scada` image with the same configuration.

If `/health` is unavailable, inspect container logs and confirm port `8080` is not already in use. If the container exits on startup, confirm the backend entrypoint `oracle.app:app` exists and that the configured Python dependencies install successfully. If SSE appears stale behind a reverse proxy, ensure proxy buffering is disabled and idle connections are allowed; the service emits heartbeat events.

## Verification status

Packaging and static simulation-guardrail checks pass in the current workspace. The full contract suite currently reaches the real FastAPI app but is blocked during lifespan startup by a backend model-construction mismatch: `oracle.auth.SessionStore` passes `display_name`, while `oracle.models.UserSnapshot` currently requires its public alias `displayName`. That source defect is intentionally not changed by this packaging/test workstream; once corrected in the backend source, rerun `python -m pytest`.
