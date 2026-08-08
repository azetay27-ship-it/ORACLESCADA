"""Serialized process runtime and the import boundary for plant logic.

The runtime talks to a plant-logic adapter through these methods:

``tag_definitions()``
    Return tag metadata keyed by public tag key.
``initial_state()``
    Return ``{"tags": {key: value}, "system": {...}}`` for startup/reset.
``tick(dt_seconds=..., now=...)``
    Advance the process and return a state update mapping.
``execute_command(action=..., mode=..., noise_scale=...)``
    Validate and apply a plant command, returning an accepted/status mapping.
``reset()``
    Restore the adapter's safe initial state and return a state update.
``health()``
    Return ``connected``, ``plc``, ``simulation`` and optional health fields.
``current_state()``
    Optionally return the adapter's current tags/equipment immediately after
    a command; the fallback implements it so command snapshots are current.

If ``oracle.logic.create_adapter`` is present, it is used. Until the separate
logic workstream supplies that factory, the small simulator below implements
the same contract and keeps Oracle useful in local simulation mode.
"""

from __future__ import annotations

import asyncio
import copy
import importlib
import inspect
import math
import random
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any, Dict, Mapping, Optional, Protocol

from .broadcaster import StateBroadcaster
from .models import (
    AlarmSnapshot,
    AuditEvent,
    CommandRequest,
    CommandResult,
    StateSnapshot,
    SystemSnapshot,
    TagSnapshot,
    TrendPoint,
    UserSnapshot,
    model_dump,
    utc_iso,
    utc_now,
)
from .settings import Settings


class PlantLogicAdapter(Protocol):
    """The only interface the API runtime requires from plant logic."""

    def tag_definitions(self) -> Mapping[str, Mapping[str, Any]]: ...

    def initial_state(self) -> Mapping[str, Any]: ...

    def tick(self, *, dt_seconds: float, now: datetime) -> Mapping[str, Any]: ...

    def execute_command(
        self,
        *,
        action: str,
        mode: Optional[str] = None,
        noise_scale: Optional[float] = None,
        actor: Optional[str] = None,
        role: Optional[str] = None,
        request_id: Optional[str] = None,
        equipment_id: Optional[str] = None,
        alarm_id: Optional[str] = None,
        expected_state_version: Optional[int] = None,
        reason: Optional[str] = None,
        parameters: Optional[Mapping[str, Any]] = None,
    ) -> Mapping[str, Any]: ...

    def reset(self, **kwargs: Any) -> Mapping[str, Any]: ...

    def health(self) -> Mapping[str, Any]: ...

    def current_state(self) -> Mapping[str, Any]: ...


TAG_DEFINITIONS: Dict[str, Dict[str, Any]] = {
    "TK-101.level": {"label": "TK-101 Level", "unit": "%", "min": 0.0, "max": 100.0, "kind": "analog"},
    "TK-102.level": {"label": "TK-102 Level", "unit": "%", "min": 0.0, "max": 100.0, "kind": "analog"},
    "FT-101.flow": {"label": "FT-101 Flow", "unit": "m\u00b3/h", "min": 0.0, "max": 200.0, "kind": "analog"},
    "PT-101.pressure": {"label": "PT-101 Pressure", "unit": "bar", "min": 0.0, "max": 8.0, "kind": "analog"},
    "AIT-101.ph": {"label": "AIT-101 pH", "unit": "pH", "min": 0.0, "max": 14.0, "kind": "analog"},
    "TT-101.temperature": {"label": "TT-101 Temperature", "unit": "\u00b0C", "min": 0.0, "max": 80.0, "kind": "analog"},
    "P-101.run": {"label": "P-101 Run", "unit": "", "min": 0.0, "max": 1.0, "kind": "digital"},
    "XV-101.open": {"label": "XV-101 Inlet", "unit": "", "min": 0.0, "max": 1.0, "kind": "digital"},
    "XV-102.open": {"label": "XV-102 Discharge", "unit": "", "min": 0.0, "max": 1.0, "kind": "digital"},
    "ESD-001.active": {"label": "ESD-001 Emergency Stop", "unit": "", "min": 0.0, "max": 1.0, "kind": "digital"},
}

INITIAL_VALUES: Dict[str, Any] = {
    "TK-101.level": 62.4,
    "TK-102.level": 41.8,
    "FT-101.flow": 0.0,
    "PT-101.pressure": 0.0,
    "AIT-101.ph": 7.1,
    "TT-101.temperature": 26.4,
    "P-101.run": False,
    "XV-101.open": True,
    "XV-102.open": True,
    "ESD-001.active": False,
}


class SimulatedPlantAdapter:
    """Safe, deterministic-enough fallback used while ``oracle.logic`` is absent."""

    def __init__(self, settings: Settings) -> None:
        self.settings = settings
        self.values = dict(INITIAL_VALUES)
        self.mode = "AUTO"
        self.noise_scale = settings.simulator_noise_scale
        self.elapsed = 0.0
        self.fault: Optional[str] = None
        self._random = random.Random(101)

    def tag_definitions(self) -> Mapping[str, Mapping[str, Any]]:
        return TAG_DEFINITIONS

    def initial_state(self) -> Mapping[str, Any]:
        return {
            "tags": dict(INITIAL_VALUES),
            "system": {"mode": self.mode, "state": "STOPPED", "connected": True, "plc": "PLC-01 / SIMULATED", "simulation": True},
            "equipment": self._equipment(),
            "capabilities": self._capabilities(),
        }

    def current_state(self) -> Mapping[str, Any]:
        state = self.initial_state()
        state["system"] = {"mode": self.mode, "state": "FAULT" if self.fault else ("RUNNING" if self.values["P-101.run"] else "STOPPED")}
        return state

    def tick(self, *, dt_seconds: float, now: datetime) -> Mapping[str, Any]:
        dt = max(0.0, min(float(dt_seconds), 5.0))
        self.elapsed += dt
        pump_running = bool(self.values["P-101.run"])
        inlet_open = bool(self.values["XV-101.open"])
        discharge_open = bool(self.values["XV-102.open"])
        noise = self.noise_scale

        flow = 0.0
        pressure = 0.0
        if pump_running and inlet_open and discharge_open and not self.values["ESD-001.active"]:
            flow = max(0.0, 126.0 + math.sin(self.elapsed / 12.0) * 9.0 + self._random.uniform(-4.0, 4.0) * noise)
            pressure = max(0.0, 4.15 + flow / 140.0 * 0.35 + self._random.uniform(-0.12, 0.12) * noise)

        self.values["FT-101.flow"] = flow
        self.values["PT-101.pressure"] = pressure
        self.values["TK-101.level"] = self._clamp(
            float(self.values["TK-101.level"])
            + dt * (0.24 if inlet_open else -0.16)
            - dt * (0.34 if pump_running else 0.0)
            + self._random.uniform(-0.12, 0.12) * noise,
            0.0,
            100.0,
        )
        self.values["TK-102.level"] = self._clamp(
            float(self.values["TK-102.level"])
            + dt * (0.18 if pump_running else -0.05)
            + self._random.uniform(-0.08, 0.08) * noise,
            0.0,
            100.0,
        )
        self.values["AIT-101.ph"] = self._clamp(
            float(self.values["AIT-101.ph"]) + math.sin(self.elapsed / 35.0) * 0.008 * dt + self._random.uniform(-0.018, 0.018) * noise,
            0.0,
            14.0,
        )
        self.values["TT-101.temperature"] = self._clamp(
            float(self.values["TT-101.temperature"]) + math.sin(self.elapsed / 40.0) * 0.02 * dt + self._random.uniform(-0.03, 0.03) * noise,
            0.0,
            80.0,
        )

        state = "FAULT" if self.fault or bool(self.values["ESD-001.active"]) else ("RUNNING" if pump_running else "STOPPED")
        return {"tags": dict(self.values), "system": {"mode": self.mode, "state": state}, "equipment": self._equipment(), "capabilities": self._capabilities()}

    def execute_command(self, *, action: str, mode: Optional[str] = None, noise_scale: Optional[float] = None, **_kwargs: Any) -> Mapping[str, Any]:
        if action == "start":
            if self.fault:
                return self._reject("FAULT_ACTIVE", "P-101 cannot start while the line is faulted.")
            if self.values["ESD-001.active"]:
                return self._reject("ESTOP_ACTIVE", "P-101 cannot start while ESD-001 is active.")
            if not self.values["XV-101.open"]:
                return self._reject("INLET_VALVE_CLOSED", "P-101 cannot start while XV-101 is closed.")
            if float(self.values["TK-101.level"]) < 10.0:
                return self._reject("INSUFFICIENT_TANK_LEVEL", "P-101 cannot start below 10% TK-101 level.")
            if self.values["P-101.run"]:
                return {"accepted": True, "status": "NOOP", "message": "P-101 is already running.", "resulting_state": "RUNNING"}
            self.values["P-101.run"] = True
            return {"accepted": True, "status": "ACCEPTED", "message": "P-101 start accepted.", "resulting_state": "RUNNING"}
        if action == "stop":
            if not self.values["P-101.run"]:
                return {"accepted": True, "status": "NOOP", "message": "P-101 is already stopped.", "resulting_state": "STOPPED"}
            self.values["P-101.run"] = False
            return {"accepted": True, "status": "ACCEPTED", "message": "P-101 stop accepted.", "resulting_state": "STOPPED"}
        if action == "open-inlet":
            if self.values["XV-101.open"]:
                return {"accepted": True, "status": "NOOP", "message": "XV-101 is already open.", "resulting_state": "OPEN"}
            self.values["XV-101.open"] = True
            return {"accepted": True, "status": "ACCEPTED", "message": "XV-101 open accepted.", "resulting_state": "OPEN"}
        if action == "open-outlet":
            if self.values["XV-102.open"]:
                return {"accepted": True, "status": "NOOP", "message": "XV-102 is already open.", "resulting_state": "OPEN"}
            self.values["XV-102.open"] = True
            return {"accepted": True, "status": "ACCEPTED", "message": "XV-102 open accepted.", "resulting_state": "OPEN"}
        if action == "close-inlet":
            if self.values["P-101.run"]:
                return self._reject("PUMP_RUNNING", "XV-101 cannot close while P-101 is running.")
            if not self.values["XV-101.open"]:
                return {"accepted": True, "status": "NOOP", "message": "XV-101 is already closed.", "resulting_state": "CLOSED"}
            self.values["XV-101.open"] = False
            return {"accepted": True, "status": "ACCEPTED", "message": "XV-101 close accepted.", "resulting_state": "CLOSED"}
        if action == "close-outlet":
            if self.values["P-101.run"]:
                return self._reject("PUMP_RUNNING", "XV-102 cannot close while P-101 is running.")
            if not self.values["XV-102.open"]:
                return {"accepted": True, "status": "NOOP", "message": "XV-102 is already closed.", "resulting_state": "CLOSED"}
            self.values["XV-102.open"] = False
            return {"accepted": True, "status": "ACCEPTED", "message": "XV-102 close accepted.", "resulting_state": "CLOSED"}
        if action == "set-mode":
            if mode not in {"AUTO", "MANUAL"}:
                return self._reject("MODE_REQUIRED", "set-mode requires AUTO or MANUAL.")
            if self.values["P-101.run"]:
                return self._reject("PROCESS_RUNNING", "Mode can only change while P-101 is stopped.")
            if mode == self.mode:
                return {"accepted": True, "status": "NOOP", "message": f"Line is already in {mode} mode.", "resulting_state": mode}
            self.mode = mode
            return {"accepted": True, "status": "ACCEPTED", "message": f"Line mode changed to {mode}.", "resulting_state": mode}
        if action == "set-sim-config":
            if noise_scale is None:
                return self._reject("NOISE_SCALE_REQUIRED", "set-sim-config requires noiseScale.")
            self.noise_scale = float(noise_scale)
            return {"accepted": True, "status": "ACCEPTED", "message": "Simulator configuration updated.", "resulting_state": "CONFIGURED"}
        return self._reject("UNSUPPORTED_ACTION", f"Unsupported plant action: {action}.")

    def reset(self, **_kwargs: Any) -> Mapping[str, Any]:
        self.values = dict(INITIAL_VALUES)
        self.mode = "AUTO"
        self.elapsed = 0.0
        self.fault = None
        return self.initial_state()

    def health(self) -> Mapping[str, Any]:
        return {"connected": self.fault is None, "plc": "PLC-01 / SIMULATED", "simulation": True, "fault": self.fault}

    @staticmethod
    def _clamp(value: float, minimum: float, maximum: float) -> float:
        return max(minimum, min(maximum, value))

    @staticmethod
    def _reject(code: str, message: str) -> Mapping[str, Any]:
        return {"accepted": False, "status": "REJECTED", "reason_code": code, "message": message}

    def _equipment(self) -> list[dict[str, Any]]:
        pump_state = "FAULT" if self.fault else ("RUNNING" if self.values["P-101.run"] else "STOPPED")
        return [
            {"equipmentId": "TK-101", "type": "tank", "state": "NORMAL", "healthy": True},
            {"equipmentId": "TK-102", "type": "tank", "state": "NORMAL", "healthy": True},
            {"equipmentId": "XV-101", "type": "valve", "state": "OPEN" if self.values["XV-101.open"] else "CLOSED", "healthy": True},
            {"equipmentId": "XV-102", "type": "valve", "state": "OPEN" if self.values["XV-102.open"] else "CLOSED", "healthy": True},
            {"equipmentId": "P-101", "type": "pump", "state": pump_state, "healthy": not bool(self.fault)},
        ]

    @staticmethod
    def _capabilities() -> list[dict[str, Any]]:
        return [
            {"id": "line.start", "action": "start", "label": "Start transfer"},
            {"id": "line.stop", "action": "stop", "label": "Stop transfer"},
            {"id": "valve.xv101.open", "action": "open-inlet", "label": "Open inlet"},
            {"id": "valve.xv101.close", "action": "close-inlet", "label": "Close inlet"},
            {"id": "alarm.ack-all", "action": "ack-all", "label": "Acknowledge all alarms"},
        ]


class OracleLogicAdapter:
    """Adapt the existing ``oracle.logic.OracleLine1Logic`` API to the runtime.

    The control engine remains the source of truth for equipment state,
    permissives, interlocks, and audit events. This adapter only translates
    the engine's JSON-ready snapshot and command vocabulary to the backend's
    stable boundary.
    """

    provides_full_snapshot = True

    def __init__(self, settings: Settings, logic_type: type[Any]) -> None:
        self.logic = logic_type(
            scan_interval=settings.scan_interval_seconds,
            noise_scale=settings.simulator_noise_scale,
            history_size=settings.history_size,
        )

    def tag_definitions(self) -> Mapping[str, Mapping[str, Any]]:
        definitions: Dict[str, Dict[str, Any]] = {}
        for item in self.logic.tag_catalog():
            tag_id = str(item["id"])
            unit = item.get("unit", "")
            if tag_id.endswith(".flow"):
                unit = "m\u00b3/h"
            elif tag_id.endswith(".temperature"):
                unit = "\u00b0C"
            definitions[str(item["id"])] = {
                "label": item.get("description") or item["id"],
                "unit": unit,
                "min": item.get("min"),
                "max": item.get("max"),
                "kind": "digital" if item.get("valueType") == "bool" else "analog",
            }
        return definitions

    def initial_state(self) -> Mapping[str, Any]:
        return self._normalise_snapshot(self.logic.snapshot())

    def current_state(self) -> Mapping[str, Any]:
        return self._normalise_snapshot(self.logic.snapshot())

    def tick(self, *, dt_seconds: float, now: datetime) -> Mapping[str, Any]:
        if dt_seconds <= 0:
            return self.current_state()
        return self._normalise_snapshot(self.logic.tick(dt=dt_seconds, now=now))

    def execute_command(
        self,
        *,
        action: str,
        mode: Optional[str] = None,
        noise_scale: Optional[float] = None,
        actor: Optional[str] = None,
        role: Optional[str] = None,
        request_id: Optional[str] = None,
        equipment_id: Optional[str] = None,
        alarm_id: Optional[str] = None,
        expected_state_version: Optional[int] = None,
        reason: Optional[str] = None,
        parameters: Optional[Mapping[str, Any]] = None,
    ) -> Mapping[str, Any]:
        action_map = {
            "open-inlet": "OPEN",
            "close-inlet": "CLOSE",
            "open-outlet": "OPEN",
            "close-outlet": "CLOSE",
            "set-mode": "SET_MODE",
            "ack-all": "ACK_ALL",
            "set-sim-config": "SET_SIM_CONFIG",
        }
        current_mode = str(self.logic.snapshot().get("system", {}).get("mode", "MANUAL"))
        if action == "start":
            logic_action = "START_LINE" if current_mode == "AUTO" else "START"
        elif action == "stop":
            logic_action = "STOP_LINE" if current_mode == "AUTO" else "STOP"
        else:
            logic_action = action_map.get(action, action)
        payload: Dict[str, Any] = {"action": logic_action}
        if request_id:
            payload["requestId"] = request_id
        if equipment_id:
            payload["equipmentId"] = equipment_id
        elif action in {"open-inlet", "close-inlet"}:
            payload["equipmentId"] = "XV-101"
        elif action in {"open-outlet", "close-outlet"}:
            payload["equipmentId"] = "XV-102"
        if mode is not None:
            payload["mode"] = mode
        if alarm_id:
            payload["alarmId"] = alarm_id
        if expected_state_version is not None:
            payload["expectedStateVersion"] = expected_state_version
        if reason:
            payload["reason"] = reason
        merged_parameters = dict(parameters or {})
        if noise_scale is not None:
            merged_parameters["noiseScale"] = noise_scale
        if merged_parameters:
            payload["parameters"] = merged_parameters
        result = self.logic.command(
            payload,
            actor=actor or "operator",
            role=role or "operator",
            request_id=request_id,
            equipment_id=equipment_id,
            mode=mode,
            alarm_id=alarm_id,
            # ProcessRuntime validates its own state version before this call;
            # the logic engine maintains a separate internal counter.
            expected_state_version=None,
            reason=reason,
        )
        return {
            "accepted": bool(result.get("accepted", False)),
            "status": result.get("status", "REJECTED" if not result.get("accepted") else "ACCEPTED"),
            "reason_code": result.get("reasonCode"),
            "message": result.get("message", "Command completed."),
            "resulting_state": result.get("resultingState"),
            "command_id": result.get("commandId"),
            "request_id": result.get("requestId", request_id),
        }

    def reset(self, **kwargs: Any) -> Mapping[str, Any]:
        actor = kwargs.get("actor")
        role = kwargs.get("role", "supervisor")
        request_id = kwargs.get("request_id")
        return self._normalise_snapshot(self.logic.reset(actor=actor, role=role, preserve_time=False))

    def health(self) -> Mapping[str, Any]:
        return self.logic.health()

    def catalogs(self) -> Mapping[str, Any]:
        return self.logic.catalogs()

    def _normalise_snapshot(self, snapshot: Mapping[str, Any]) -> Mapping[str, Any]:
        system = snapshot.get("system", {})
        normal_system = {
            "name": system.get("name", "Oracle"),
            "site": system.get("site", "NILIT"),
            "process_line": system.get("processLine", "NILIT Line 1"),
            "mode": system.get("mode", "MANUAL"),
            "state": system.get("state", "STOPPED"),
            "connected": system.get("connected", True),
            "plc": system.get("plc", "PLC-01 / SIMULATED"),
            "scan_ms": system.get("scanMs", 1000),
            "simulation": system.get("simulation", True),
            "sequence": system.get("sequence"),
        }
        tags: Dict[str, Any] = {}
        for key, raw in (snapshot.get("tags", {}) or {}).items():
            tags[key] = {
                "value": raw.get("value"),
                "quality": raw.get("quality", "GOOD"),
            }
        alarms = []
        for raw in snapshot.get("alarms", []) or []:
            alarms.append({
                "id": raw.get("id"),
                "source": raw.get("source", "logic"),
                "message": raw.get("message", ""),
                "severity": raw.get("severity", "WARNING"),
                "active": raw.get("active", True),
                "acknowledged": raw.get("acknowledged", False),
                "since": raw.get("since", utc_iso()),
                "last_changed_at": raw.get("lastChangedAt", utc_iso()),
                "acknowledged_at": raw.get("acknowledgedAt"),
                "acknowledged_by": raw.get("acknowledgedBy"),
                "cleared_at": raw.get("clearedAt"),
                "activation_count": raw.get("activationCount"),
            })
        events = []
        for raw in snapshot.get("events", []) or []:
            events.append({
                "id": raw.get("id", f"evt-{time.time_ns()}"),
                "time": raw.get("time", utc_iso()),
                "source": raw.get("source", "logic"),
                "message": raw.get("message", ""),
                "severity": raw.get("severity", "INFO"),
                "actor": raw.get("actor"),
                "role": raw.get("role"),
                "action": raw.get("action"),
                "result": raw.get("result"),
                "command_id": raw.get("commandId"),
                "equipment_id": raw.get("equipmentId"),
                "reason_code": raw.get("reasonCode"),
                "state_version": raw.get("stateVersion"),
                "related_alarm_id": raw.get("relatedAlarmId"),
            })
        equipment = snapshot.get("equipment", []) or []
        if isinstance(equipment, Mapping):
            equipment = list(equipment.values())
        catalogs = self.logic.catalogs() if hasattr(self.logic, "catalogs") else {"equipment": []}
        capabilities = []
        for item in catalogs.get("equipment", []) if isinstance(catalogs, Mapping) else []:
            equipment_id = item.get("equipmentId", item.get("id"))
            for capability in item.get("capabilities", []) or []:
                capabilities.append({
                    "id": f"{equipment_id}.{str(capability).lower()}",
                    "equipmentId": equipment_id,
                    "action": str(capability),
                    "label": f"{capability} {equipment_id}",
                })
        return {
            "tags": tags,
            "system": normal_system,
            "alarms": alarms,
            "events": events,
            "equipment": list(equipment),
            "capabilities": capabilities,
            "permissives": list(snapshot.get("permissives", []) or []),
            "interlocks": list(snapshot.get("interlocks", []) or []),
            "alarm_history": list(snapshot.get("alarmHistory", []) or []),
            "faults": [str(item) for item in (snapshot.get("faults", []) or [])],
            "sequence": system.get("sequence"),
        }


def load_logic_adapter(settings: Settings) -> PlantLogicAdapter:
    """Load the separate plant-logic factory, or use the documented fallback."""

    try:
        module = importlib.import_module("oracle.logic")
    except ModuleNotFoundError as exc:
        if exc.name not in {"oracle.logic", "oracle"}:
            raise
        return SimulatedPlantAdapter(settings)
    factory = getattr(module, "create_adapter", None)
    if factory is None:
        logic_type = getattr(module, "OracleLine1Logic", None) or getattr(module, "Line1Logic", None)
        if logic_type is not None:
            return OracleLogicAdapter(settings, logic_type)
        return SimulatedPlantAdapter(settings)
    try:
        adapter = factory(settings)
    except TypeError:
        adapter = factory()
    return adapter


class ProcessRuntime:
    """Own the API-facing state, scan lifecycle, and serialized mutations."""

    def __init__(self, settings: Settings, broadcaster: Optional[StateBroadcaster] = None) -> None:
        self.settings = settings
        self.broadcaster = broadcaster or StateBroadcaster(queue_size=settings.sse_queue_size)
        self.logic: PlantLogicAdapter = load_logic_adapter(settings)
        self.lock = asyncio.Lock()
        self._stop_event = asyncio.Event()
        self._scan_task: Optional[asyncio.Task[None]] = None
        self._last_tick_monotonic = time.monotonic()
        self._state_version = 0
        self._updated_at = utc_iso()
        self._system: Dict[str, Any] = {
            "name": "Oracle",
            "site": "NILIT",
            "process_line": "NILIT Line 1",
            "mode": "AUTO",
            "state": "STOPPED",
            "connected": True,
            "plc": "PLC-01 / SIMULATED",
            "scan_ms": int(settings.scan_interval_seconds * 1000),
            "simulation": True,
            "sequence": None,
        }
        self._tag_defs: Dict[str, Dict[str, Any]] = copy.deepcopy(TAG_DEFINITIONS)
        self._tags: Dict[str, Dict[str, Any]] = {}
        self._alarms: Dict[str, Dict[str, Any]] = {}
        self._events: list[Dict[str, Any]] = []
        self._equipment: list[Dict[str, Any]] = []
        self._capabilities: list[Dict[str, Any]] = []
        self._permissives: list[Dict[str, Any]] = []
        self._interlocks: list[Dict[str, Any]] = []
        self._alarm_history: list[Dict[str, Any]] = []
        self._faults: list[str] = []
        self._command_results: Dict[str, CommandResult] = {}
        self._uses_full_logic_snapshots = bool(getattr(self.logic, "provides_full_snapshot", False))
        self._seed_state(self._safe_initial_state())
        self._append_event("runtime", "Oracle runtime initialized in simulation mode.")

    async def initialize(self) -> None:
        initial = await self._invoke("initial_state")
        async with self.lock:
            self._seed_state(initial or self._safe_initial_state())
            self._updated_at = utc_iso()
            self._last_tick_monotonic = time.monotonic()

    async def start(self) -> None:
        if self._scan_task and not self._scan_task.done():
            return
        self._stop_event.clear()
        await self.tick_once(dt_seconds=0.0)
        self._scan_task = asyncio.create_task(self._scan_loop(), name="oracle-scan-loop")

    async def stop(self) -> None:
        self._stop_event.set()
        task = self._scan_task
        if task and not task.done():
            task.cancel()
            try:
                await task
            except asyncio.CancelledError:
                pass
        self._scan_task = None

    async def _scan_loop(self) -> None:
        while not self._stop_event.is_set():
            started = time.monotonic()
            try:
                await self.tick_once()
            except asyncio.CancelledError:
                raise
            except Exception as exc:  # keep the service alive and expose a bad health state
                async with self.lock:
                    self._system["connected"] = False
                    self._system["state"] = "FAULT"
                    self._append_event("runtime", f"Scan error: {exc}", severity="HIGH")
                    self._state_version += 1
                    snapshot = self._snapshot_locked()
                await self.broadcaster.publish(model_dump(snapshot))
            elapsed = time.monotonic() - started
            try:
                await asyncio.wait_for(self._stop_event.wait(), timeout=max(0.0, self.settings.scan_interval_seconds - elapsed))
            except asyncio.TimeoutError:
                pass

    async def tick_once(self, dt_seconds: Optional[float] = None) -> StateSnapshot:
        now_monotonic = time.monotonic()
        if dt_seconds is None:
            dt_seconds = max(0.0, min(now_monotonic - self._last_tick_monotonic, 5.0))
        now = utc_now()
        async with self.lock:
            update = await self._invoke("tick", dt_seconds=float(dt_seconds), now=now)
            self._apply_update(update or {})
            if not self._uses_full_logic_snapshots:
                self._evaluate_alarms(now)
            self._last_tick_monotonic = now_monotonic
            self._updated_at = utc_iso(now)
            self._state_version += 1
            snapshot = self._snapshot_locked()
        await self.broadcaster.publish(model_dump(snapshot))
        return snapshot

    async def get_snapshot(self) -> StateSnapshot:
        async with self.lock:
            return self._snapshot_locked()

    async def health(self) -> Dict[str, Any]:
        async with self.lock:
            adapter_health = await self._invoke("health")
            scan_age = max(0.0, time.monotonic() - self._last_tick_monotonic)
            scan_healthy = self._scan_task is not None and not self._scan_task.done() and scan_age <= self.settings.stale_after_seconds
            connected = bool((adapter_health or {}).get("connected", self._system.get("connected", False))) and scan_healthy
            return {
                "ok": connected,
                "service": self.settings.service_name,
                "simulator": "RUNNING" if scan_healthy else "STALE",
                "connected": connected,
                "plc": (adapter_health or {}).get("plc", self._system.get("plc")),
                "simulation": bool((adapter_health or {}).get("simulation", True)),
                "scanAgeMs": int(scan_age * 1000),
                "stateVersion": self._state_version,
                "subscriberCount": await self.broadcaster.subscriber_count(),
            }

    async def execute_command(self, request: CommandRequest, user: UserSnapshot) -> CommandResult:
        action = self._normalise_api_action(request)
        request_id = request.client_command_id or request.request_id
        async with self.lock:
            if request_id and request_id in self._command_results:
                return copy.deepcopy(self._command_results[request_id])

            command_id = f"cmd-{time.time_ns()}"
            current_version = self._state_version
            if request.expected_state_version is not None and request.expected_state_version != current_version:
                result = self._result(False, "REJECTED", action, command_id, request_id, current_version, "STATE_VERSION_CONFLICT", "The state changed before this command was applied.")
                if not self._uses_full_logic_snapshots:
                    self._append_command_event(result, user, request)
                self._state_version += 1
                result = result.model_copy(update={"state_version": self._state_version}) if hasattr(result, "model_copy") else result.copy(update={"state_version": self._state_version})
                self._remember_command(request_id, result)
                snapshot = self._snapshot_locked()
                await self.broadcaster.publish(model_dump(snapshot))
                return result

            if action in {"set-mode", "reset-simulator", "set-sim-config"} and user.role != "supervisor":
                result = self._result(False, "REJECTED", action, command_id, request_id, current_version, "SUPERVISOR_REQUIRED", "Supervisor permission is required for this command.")
                if not self._uses_full_logic_snapshots:
                    self._append_command_event(result, user, request)
                self._state_version += 1
                result = result.model_copy(update={"state_version": self._state_version}) if hasattr(result, "model_copy") else result.copy(update={"state_version": self._state_version})
                self._remember_command(request_id, result)
                snapshot = self._snapshot_locked()
                await self.broadcaster.publish(model_dump(snapshot))
                return result

            if action == "ack-all" and not self._uses_full_logic_snapshots:
                changed = self._acknowledge_all(user)
                status = "ACCEPTED" if changed else "NOOP"
                result = self._result(True, status, action, command_id, request_id, current_version, None, "Active alarms acknowledged." if changed else "No active unacknowledged alarms.")
            elif action == "reset-simulator":
                for alarm_id in tuple(self._alarms):
                    self._append_event("alarm", f"Alarm {alarm_id} cleared by simulator reset.", severity="INFO", actor=user.username, role=user.role)
                self._alarms.clear()
                self._apply_update(await self._invoke("reset", actor=user.username, role=user.role, request_id=request_id))
                result = self._result(True, "ACCEPTED", action, command_id, request_id, current_version, None, "Simulator reset accepted.", "STOPPED")
            else:
                adapter_action = action
                if action == "set-sim-config":
                    adapter_action = "set-sim-config"
                update = await self._invoke(
                    "execute_command",
                    action=adapter_action,
                    mode=request.mode,
                    noise_scale=request.noise_scale,
                    actor=user.username,
                    role=user.role,
                    request_id=request_id,
                    equipment_id=request.equipment_id,
                    alarm_id=request.alarm_id,
                    expected_state_version=request.expected_state_version,
                    reason=request.reason,
                    parameters=request.parameters or {},
                )
                update = update or {}
                if "tags" not in update:
                    update = {**update, **(await self._invoke("current_state"))}
                accepted = bool(update.get("accepted", False))
                status = str(update.get("status", "ACCEPTED" if accepted else "REJECTED"))
                self._apply_update(update)
                if accepted and not self._uses_full_logic_snapshots:
                    self._evaluate_alarms(utc_now())
                result = self._result(
                    accepted,
                    status if status in {"ACCEPTED", "NOOP", "REJECTED", "FAILED"} else ("ACCEPTED" if accepted else "FAILED"),
                    action,
                    command_id,
                    request_id,
                    current_version,
                    update.get("reason_code"),
                    str(update.get("message", "Command accepted." if accepted else "Command rejected.")),
                    update.get("resulting_state"),
                )

            if not self._uses_full_logic_snapshots:
                self._append_command_event(result, user, request)
            self._state_version += 1
            result = result.model_copy(update={"state_version": self._state_version}) if hasattr(result, "model_copy") else result.copy(update={"state_version": self._state_version})
            self._updated_at = utc_iso()
            self._remember_command(request_id, result)
            snapshot = self._snapshot_locked()
        await self.broadcaster.publish(model_dump(snapshot))
        return result

    async def session_snapshot(self) -> Dict[str, Any]:
        snapshot = await self.get_snapshot()
        return model_dump(snapshot)

    async def _invoke(self, method_name: str, **kwargs: Any) -> Mapping[str, Any]:
        method = getattr(self.logic, method_name, None)
        if method is None:
            return {}
        result = method(**kwargs) if kwargs else method()
        if inspect.isawaitable(result):
            result = await result
        if not isinstance(result, Mapping):
            return {}
        return result

    def _safe_initial_state(self) -> Mapping[str, Any]:
        method = getattr(self.logic, "initial_state", None)
        if method is None:
            return {"tags": INITIAL_VALUES}
        result = method()
        return result if isinstance(result, Mapping) else {"tags": INITIAL_VALUES}

    def _seed_state(self, initial: Mapping[str, Any]) -> None:
        self._tag_defs = copy.deepcopy(dict(self._tag_defs or TAG_DEFINITIONS))
        try:
            supplied_defs = self.logic.tag_definitions()
            if supplied_defs:
                self._tag_defs = copy.deepcopy(dict(supplied_defs))
        except (AttributeError, TypeError):
            pass
        supplied_tags = initial.get("tags", {}) if isinstance(initial, Mapping) else {}
        values = dict(INITIAL_VALUES)
        if isinstance(supplied_tags, Mapping):
            for key, raw in supplied_tags.items():
                values[key] = raw.get("value") if isinstance(raw, Mapping) and "value" in raw else raw
        now_ms = int(time.time() * 1000)
        self._tags = {}
        for key, definition in self._tag_defs.items():
            value = values.get(key, 0.0 if definition.get("kind") != "digital" else False)
            self._tags[key] = {
                "value": self._normalise_value(key, value),
                "quality": "GOOD",
                "history": [{"time": now_ms, "value": self._trend_value(value)}],
            }
        supplied_system = initial.get("system", {}) if isinstance(initial, Mapping) else {}
        if isinstance(supplied_system, Mapping):
            self._system.update({key: supplied_system[key] for key in supplied_system if key in self._system})
        self._equipment = copy.deepcopy(list(initial.get("equipment", []))) if isinstance(initial, Mapping) else []
        self._capabilities = copy.deepcopy(list(initial.get("capabilities", []))) if isinstance(initial, Mapping) else []
        self._permissives = copy.deepcopy(list(initial.get("permissives", []))) if isinstance(initial, Mapping) else []
        self._interlocks = copy.deepcopy(list(initial.get("interlocks", []))) if isinstance(initial, Mapping) else []
        self._alarm_history = copy.deepcopy(list(initial.get("alarm_history", []))) if isinstance(initial, Mapping) else []
        self._faults = [str(item) for item in (initial.get("faults", []) if isinstance(initial, Mapping) else [])]
        if isinstance(initial, Mapping) and "sequence" in initial:
            self._system["sequence"] = initial.get("sequence")
        if self._uses_full_logic_snapshots:
            supplied_alarms = initial.get("alarms", []) if isinstance(initial, Mapping) else []
            supplied_events = initial.get("events", []) if isinstance(initial, Mapping) else []
            if isinstance(supplied_alarms, list):
                self._alarms = {str(item["id"]): copy.deepcopy(item) for item in supplied_alarms if isinstance(item, Mapping) and item.get("id")}
            if isinstance(supplied_events, list):
                self._events = [copy.deepcopy(item) for item in supplied_events if isinstance(item, Mapping)]

    def _apply_update(self, update: Mapping[str, Any]) -> None:
        if not update:
            return
        tags = update.get("tags", {})
        if isinstance(tags, Mapping):
            for key, raw in tags.items():
                if key not in self._tag_defs:
                    continue
                quality = "GOOD"
                value = raw
                if isinstance(raw, Mapping):
                    value = raw.get("value", self._tags[key]["value"])
                    quality = raw.get("quality", "GOOD")
                self._tags[key]["value"] = self._normalise_value(key, value)
                self._tags[key]["quality"] = quality
                self._tags[key]["history"].append({"time": int(time.time() * 1000), "value": self._trend_value(value)})
                self._tags[key]["history"] = self._tags[key]["history"][-self.settings.history_size :]
        system = update.get("system", {})
        if isinstance(system, Mapping):
            for key, value in system.items():
                if key in self._system:
                    self._system[key] = value
        if "equipment" in update and isinstance(update["equipment"], list):
            self._equipment = copy.deepcopy(update["equipment"])
        if "capabilities" in update and isinstance(update["capabilities"], list):
            self._capabilities = copy.deepcopy(update["capabilities"])
        for key, destination in (("permissives", "_permissives"), ("interlocks", "_interlocks"), ("alarm_history", "_alarm_history")):
            if key in update and isinstance(update[key], list):
                setattr(self, destination, copy.deepcopy(update[key]))
        if "faults" in update and isinstance(update["faults"], list):
            self._faults = [str(item) for item in update["faults"]]
        if "sequence" in update:
            self._system["sequence"] = update.get("sequence")
        if self._uses_full_logic_snapshots:
            if isinstance(update.get("alarms"), list):
                self._alarms = {str(item["id"]): copy.deepcopy(item) for item in update["alarms"] if isinstance(item, Mapping) and item.get("id")}
            if isinstance(update.get("events"), list):
                self._events = [copy.deepcopy(item) for item in update["events"] if isinstance(item, Mapping)]

    def _evaluate_alarms(self, now: datetime) -> None:
        values = {key: value["value"] for key, value in self._tags.items()}
        rules = {
            "TK101-LOW": (float(values.get("TK-101.level", 0)) < 30.0, "TK-101", "TK-101 level below 30%.", "WARNING"),
            "TK101-HIGH": (float(values.get("TK-101.level", 0)) > 85.0, "TK-101", "TK-101 level above 85%.", "HIGH"),
            "AIT101-PH": (float(values.get("AIT-101.ph", 7.0)) < 6.5 or float(values.get("AIT-101.ph", 7.0)) > 8.5, "AIT-101", "AIT-101 pH outside 6.5\u20138.5.", "WARNING"),
            "PT101-HIGH": (float(values.get("PT-101.pressure", 0)) > 5.5, "PT-101", "PT-101 pressure above 5.5 bar.", "HIGH"),
        }
        now_value = utc_iso(now)
        for alarm_id, (active, source, message, severity) in rules.items():
            current = self._alarms.get(alarm_id)
            if active and current is None:
                self._alarms[alarm_id] = {
                    "id": alarm_id,
                    "source": source,
                    "message": message,
                    "severity": severity,
                    "active": True,
                    "acknowledged": False,
                    "since": now_value,
                    "last_changed_at": now_value,
                    "acknowledged_at": None,
                    "acknowledged_by": None,
                    "cleared_at": None,
                }
                self._append_event("alarm", f"Alarm active: {message}", severity=severity)
            elif not active and current is not None:
                self._append_event("alarm", f"Alarm cleared: {message}", severity="INFO")
                self._alarms.pop(alarm_id, None)

    def _acknowledge_all(self, user: UserSnapshot) -> bool:
        active = [alarm for alarm in self._alarms.values() if not alarm["acknowledged"]]
        if not active:
            return False
        now = utc_iso()
        for alarm in active:
            alarm["acknowledged"] = True
            alarm["acknowledged_at"] = now
            alarm["acknowledged_by"] = user.username
            alarm["last_changed_at"] = now
        self._append_event("alarm", f"{len(active)} active alarm(s) acknowledged.", actor=user.username, role=user.role)
        return True

    def _append_command_event(self, result: CommandResult, user: UserSnapshot, request: CommandRequest) -> None:
        severity = "INFO" if result.accepted else "WARNING"
        self._append_event(
            "command",
            result.message,
            severity=severity,
            actor=user.username,
            role=user.role,
            command_id=result.command_id,
            equipment_id=request.equipment_id,
            reason_code=result.reason_code,
        )

    def _append_event(self, source: str, message: str, *, severity: str = "INFO", actor: Optional[str] = None, role: Optional[str] = None, command_id: Optional[str] = None, equipment_id: Optional[str] = None, reason_code: Optional[str] = None) -> None:
        event = {
            "id": f"evt-{time.time_ns()}",
            "time": utc_iso(),
            "source": source,
            "message": message,
            "severity": severity,
            "actor": actor,
            "role": role,
            "command_id": command_id,
            "equipment_id": equipment_id,
            "reason_code": reason_code,
        }
        self._events.append(event)
        self._events = self._events[-self.settings.event_history_size :]

    def _result(self, accepted: bool, status: str, action: str, command_id: str, request_id: Optional[str], state_version: int, reason_code: Optional[str], message: str, resulting_state: Optional[str] = None) -> CommandResult:
        return CommandResult(
            accepted=accepted,
            status=status,  # type: ignore[arg-type]
            action=action,
            command_id=command_id,
            request_id=request_id,
            state_version=state_version,
            reason_code=reason_code,
            message=message,
            resulting_state=resulting_state,
        )

    def _remember_command(self, request_id: Optional[str], result: CommandResult) -> None:
        if request_id:
            self._command_results[request_id] = copy.deepcopy(result)
            if len(self._command_results) > 1000:
                oldest = next(iter(self._command_results))
                self._command_results.pop(oldest, None)

    def _snapshot_locked(self) -> StateSnapshot:
        tags: Dict[str, TagSnapshot] = {}
        for key, definition in self._tag_defs.items():
            value = self._tags.get(key, {}).get("value", False if definition.get("kind") == "digital" else 0.0)
            tags[key] = TagSnapshot(
                value=value,
                unit=str(definition.get("unit", "")),
                min_value=definition.get("min"),
                max_value=definition.get("max"),
                quality=self._tags.get(key, {}).get("quality", "GOOD"),
                label=str(definition.get("label", key)),
                history=[TrendPoint(time=int(point["time"]), value=float(point["value"])) for point in self._tags.get(key, {}).get("history", [])],
            )
        system = dict(self._system)
        system["updated_at"] = self._updated_at
        return StateSnapshot(
            schema_version=1,
            state_version=self._state_version,
            emitted_at=utc_iso(),
            system=SystemSnapshot(**system),
            tags=tags,
            alarms=[AlarmSnapshot(**alarm) for alarm in self._sorted_alarms()],
            events=[AuditEvent(**event) for event in self._events[-self.settings.event_history_size :]],
            equipment=copy.deepcopy(self._equipment),
            capabilities=copy.deepcopy(self._capabilities),
            permissives=copy.deepcopy(self._permissives),
            interlocks=copy.deepcopy(self._interlocks),
            alarm_history=copy.deepcopy(self._alarm_history),
            faults=copy.deepcopy(self._faults),
        )

    @staticmethod
    def _normalise_api_action(request: CommandRequest) -> str:
        raw = (request.action or request.command or "").strip()
        normalized = raw.lower().replace("_", "-").replace(" ", "-")
        aliases = {
            "start-pump": "start",
            "start-p101": "start",
            "stop-pump": "stop",
            "stop-p101": "stop",
            "ack-all-alarms": "ack-all",
            "acknowledge-all": "ack-all",
            "reset-line": "reset-simulator",
            "reset-simulator": "reset-simulator",
            "set-mode": "set-mode",
            "set-sim-config": "set-sim-config",
        }
        if normalized in {"open", "close"} and request.equipment_id:
            equipment = request.equipment_id.upper()
            if equipment == "XV-101":
                return "open-inlet" if normalized == "open" else "close-inlet"
            if equipment == "XV-102":
                return "open-outlet" if normalized == "open" else "close-outlet"
        return aliases.get(normalized, normalized)

    def _sorted_alarms(self) -> list[Dict[str, Any]]:
        severity_rank = {"HIGH": 0, "WARNING": 1, "INFO": 2}
        return sorted(self._alarms.values(), key=lambda alarm: (severity_rank.get(alarm["severity"], 3), alarm["since"]))

    def _normalise_value(self, key: str, value: Any) -> Any:
        definition = self._tag_defs.get(key, {})
        if definition.get("kind") == "digital":
            return bool(value)
        try:
            numeric = float(value)
        except (TypeError, ValueError):
            return 0.0
        minimum = definition.get("min")
        maximum = definition.get("max")
        if minimum is not None:
            numeric = max(float(minimum), numeric)
        if maximum is not None:
            numeric = min(float(maximum), numeric)
        return numeric

    @staticmethod
    def _trend_value(value: Any) -> float:
        return 1.0 if isinstance(value, bool) and value else 0.0 if isinstance(value, bool) else float(value)
