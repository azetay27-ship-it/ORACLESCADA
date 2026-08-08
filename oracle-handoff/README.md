# Oracle — NILIT SCADA / HMI handoff

This folder is the portable handoff for the **Oracle** project. Oracle is intended to become the main NILIT industrial SCADA application: a browser-based HMI, a plant-logic runtime, and an editor for reusable process screens.

The project was built from scratch in the Codex workspace. This README is written for the next Codex instance or developer who continues the work.

## Contents

    oracle-handoff/
    ├── README.md                 this handoff and continuation guide
    ├── oracle/                   current Oracle application
    │   ├── oracle/               Python backend and industrial logic
    │   ├── public/               browser HMI and SVG screen editor
    │   ├── tests/                automated tests
    │   ├── Dockerfile
    │   ├── compose.yaml
    │   ├── pyproject.toml
    │   └── README.md             project-specific run notes
    └── scada-hmi/                earlier AquaPure/SCADA reference scaffold

oracle/ is the active application. scada-hmi/ is retained because it was part of the earlier design/scaffold work and may contain useful reference material; do not treat it as the production Oracle runtime unless a future task explicitly asks for that.

Temporary Python caches, test caches, generated screen-data, and installed dependency folders were intentionally left out of this portable folder.

## What has been implemented

### Backend and application shell

- FastAPI application factory in oracle/oracle/app.py.
- Uvicorn-compatible entrypoint.
- Static browser application served from oracle/public/.
- Health endpoint and structured API responses.
- Pydantic models with strict validation and assignment validation.
- Configuration through environment variables in oracle/oracle/settings.py.
- Separation between HTTP routers, runtime state, screen storage, authentication, and the logic engine.

### Authentication and roles

- Local operator and supervisor roles.
- HttpOnly oracle_session cookie sessions.
- Role-aware control authorization.
- Demo credentials for local development:
  - operator / operator
  - supervisor / supervisor
- These credentials are for a local demo only. Set real password environment variables before exposing the application to any network.

### State and streaming APIs

The main endpoints are:

    GET  /health
    POST /api/auth/login
    POST /api/auth/logout
    GET  /api/me
    GET  /api/state
    GET  /api/stream
    POST /api/commands
    POST /api/command             legacy single-command compatibility endpoint

The state response includes process tags, equipment state, alarms, audit entries, mode, and a monotonically increasing state version. /api/stream provides server-sent state updates; the HMI handles reconnects and stale connection status.

### Industrial logic and simulation

The logic implementation is under oracle/oracle/logic/:

- catalog.py — equipment, tag, alarm, and capability catalog.
- models.py — typed process and equipment models.
- tags.py — tag definitions and tag quality/value handling.
- engine.py — deterministic one-second simulation and command/interlock behavior.

The modeled NILIT Line 1 demo includes:

- TK-101 and TK-102 tanks.
- XV-101 and XV-102 valves.
- P-101 / M-101 pump-motor equipment.
- LIT, FT, PT, AIT, and TT instrumentation tags.
- PLC-01 and ESD-001 system indicators.
- AUTO and MANUAL modes.
- Valve open/close commands.
- Pump start/stop commands.
- Permissives, interlocks, trips, and alarms.
- Audit trail and recent trend history.

This is a simulator and software architecture boundary, not a certified control system. It currently performs no OPC UA, Modbus, PLC, historian, or physical I/O communication. Do not connect this code to live equipment without a separate engineering, cybersecurity, functional-safety, and commissioning review.

### HMI

The browser HMI is in oracle/public/:

- Dark industrial Oracle/NILIT visual language.
- Login screen.
- Role-aware controls and supervisor-only actions.
- Live process mimic with tanks, valves, pump, instruments, and status indicators.
- Alarm list and acknowledgement workflow.
- Trend display.
- Audit export.
- Connection/stale-data indication.
- Navigation to the screen editor.

### Screen editor

The screen editor is in:

    oracle/public/editor/editor.js
    oracle/public/editor/editor-model.js
    oracle/public/editor/editor.css

Implemented editor behavior includes:

- Reusable industrial parts and templates.
- Drag/drop placement.
- Grid and snap-to-grid.
- Pan and zoom.
- Multi-select.
- Smart alignment guides.
- Resize handles.
- Properties and binding metadata.
- Layer ordering.
- Connectors.
- Undo and redo.
- Runtime/edit separation.
- Client-side validation and custom editor events.

The server-side screen store is oracle/oracle/screen_store.py. It supports JSON screen documents, draft/published revisions, validation, a default Line 1 overview screen, and an in-memory fallback when the configured filesystem is read-only.

Screen/editor endpoints are:

    GET  /api/screens
    GET  /api/screens/{screen_id}
    PUT  /api/screens/{screen_id}
    POST /api/screens/{screen_id}/duplicate
    POST /api/screens/{screen_id}/validate
    POST /api/screens/{screen_id}/publish
    GET  /api/editor/parts
    GET  /api/editor/templates
    GET  /api/editor/tag-catalog
    GET  /api/editor/capabilities

Screen writes and publishing require supervisor authorization.

## Run locally

Use Python 3.11+ if available. From this folder:

    Set-Location .\oracle
    python -m venv .venv
    .\.venv\Scripts\Activate.ps1
    python -m pip install -e ".[test]"
    python -m uvicorn oracle.app:app --host 0.0.0.0 --port 8080

Open http://localhost:8080.

If PowerShell execution policy prevents activation, run the Python executable in .venv directly or use another shell. The application can also be run with the project's Dockerfile and compose.yaml:

    Set-Location .\oracle
    docker compose up --build

The compose configuration uses /tmp/oracle-screens as the container screen-store location. The local default is ./screen-data; this directory is generated at runtime and is not included in this handoff.

## Test and verification status

From oracle/, run:

    $env:PYTHONPATH = (Get-Location).Path
    python -m pytest -q -p no:cacheprovider

The last verification in the original Codex session produced:

    21 passed, 4 skipped

The skips were intentional/conditional:

- Browser smoke requires ORACLE_BROWSER_URL and a live HMI.
- SSE integration is opt-in with ORACLE_RUN_SSE_TESTS=1.
- Two deterministic-state tests skip when their starting process conditions are not present.

Additional checks completed during implementation:

- Python compilation passed.
- JavaScript syntax checks passed for the HMI and editor files.
- ASGI smoke checks passed for health, authentication, role restrictions, state, commands, and static HTML.
- Screen API smoke checks passed for listing, supervisor save, validation, and publishing.
- Docker was not available on the original machine, so a Docker build was not executed.

## Configuration

The main environment variables are:

    ORACLE_OPERATOR_PASSWORD       local operator password
    ORACLE_SUPERVISOR_PASSWORD     local supervisor password
    ORACLE_SESSION_TTL_SECONDS     session lifetime
    ORACLE_COOKIE_SECURE            set true when serving over HTTPS
    ORACLE_SCAN_INTERVAL_SECONDS    simulator scan interval
    ORACLE_SCREEN_STORE             JSON screen storage directory
    ORACLE_BROWSER_URL              browser smoke-test target
    ORACLE_RUN_SSE_TESTS            opt-in SSE integration tests

Inspect oracle/oracle/settings.py for defaults and exact parsing behavior before changing deployment configuration.

## Suggested continuation order

A new Codex instance should begin here:

1. Read this file.
2. Read oracle/README.md.
3. Inspect oracle/oracle/app.py, runtime.py, logic/engine.py, and screen_store.py.
4. Run the test suite before making changes.
5. Start the local app and exercise the operator and supervisor flows.
6. Keep the logic engine, HTTP API, HMI runtime, and screen editor as separate layers.

Do not infer real NILIT plant tag names, process sequences, or safety requirements from this demo. Those inputs were not supplied in the original task and must be obtained from the plant/control-system engineering team.

## Important future work

The current project is a strong application prototype, not a finished industrial deployment. Likely next work includes:

- Replace the simulator boundary with a reviewed OPC UA/Modbus/PLC adapter.
- Add historian persistence and retention/backup policy.
- Add a real configuration and migration strategy for screen documents.
- Add SSO/identity integration, password rotation, and stronger session/security policy.
- Add TLS, reverse-proxy deployment, audit retention, and security hardening.
- Add redundancy/availability behavior and clock/time-quality handling.
- Define real NILIT equipment, tag, alarm, permissive, and interlock specifications.
- Add end-to-end browser tests against a running deployment.
- Add CI for Python, JavaScript, container build, and security checks.
- Complete a usability and functional-safety review with operators and controls engineers.

## Handoff notes

- The project name is Oracle.
- Oracle is intended to be the main NILIT SCADA app.
- The requested parallel work streams were represented in the codebase as two cooperating areas: UX/UI screen editing in public/editor/, and plant logic/control behavior in oracle/logic/.
- No external cloud repository was successfully published during the original session; this folder is the complete local handoff artifact.
- The previous ZIP artifact, if present next to this folder as outputs/oracle-project.zip, is an older convenience copy. This directory is the requested non-ZIP deliverable and should be copied as a whole to the hard drive.

