"""Simulator-first control logic for Oracle NILIT Line 1.

This module is intentionally independent of FastAPI and any physical I/O.  It
models the control boundary that a backend can call, while the only output
adapter in v1 is the deterministic in-memory simulator.

The primary interface is :class:`OracleLine1Logic`::

    logic.snapshot()
    logic.tick()
    logic.command({"action": "START"}, actor="operator", role="operator")
    logic.reset()
    logic.health()
    logic.tag_catalog()
    logic.equipment_catalog()
"""

from __future__ import annotations

import math
import random
from collections import deque
from datetime import datetime, timedelta, timezone
from typing import Any, Callable, Mapping, Optional

from .catalog import EQUIPMENT_CATALOG, TAG_CATALOG, equipment_catalog, tag_catalog
from .models import (
    AlarmRecord,
    AuditEvent,
    CommandResult,
    CommandStatus,
    EquipmentStatus,
    Interlock,
    LineState,
    Mode,
    Permissive,
    PumpState,
    Quality,
    Severity,
    ValveState,
)
from .tags import TagRegistry


Clock = Callable[[], datetime]


def _utc_now() -> datetime:
    return datetime.now(timezone.utc)


def _iso(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


class OracleLine1Logic:
    """Safe-default, deterministic simulator and control engine.

    The default scan is one second and the default noise scale is zero, making
    unit and integration behavior repeatable.  A non-zero ``noise_scale`` can
    be used for operator demonstrations without changing the control rules.
    ``seed`` makes that noise repeatable.
    """

    SCHEMA_VERSION = 1
    VALVE_TRAVEL_SECONDS = 2.0
    VALVE_TIMEOUT_SECONDS = 5.0
    MOTOR_START_SECONDS = 3.0
    MOTOR_START_TIMEOUT_SECONDS = 5.0
    NO_FLOW_SECONDS = 5.0
    HISTORY_SIZE = 90
    AUDIT_SIZE = 200

    def __init__(
        self,
        *,
        scan_interval: float = 1.0,
        start_time: datetime | None = None,
        clock: Clock | None = None,
        seed: int = 1,
        noise_scale: float = 0.0,
        history_size: int = HISTORY_SIZE,
    ) -> None:
        self.scan_interval = max(0.1, float(scan_interval))
        self._clock: Clock = clock or _utc_now
        self._epoch = (start_time or self._clock()).astimezone(timezone.utc)
        self._wall_last_tick = self._clock()
        self._rng = random.Random(seed)
        self._seed = seed
        self._noise_scale = max(0.0, min(2.0, float(noise_scale)))
        self._history_size = max(1, int(history_size))
        self._id_counter = 0
        self._state_version = 0
        self._sim_seconds = 0.0
        self._timestamp = self._epoch
        self._mode = Mode.MANUAL
        self._line_state = LineState.STOPPED
        self._auto_phase = "IDLE"
        self._auto_requested = False
        self._close_after_stop = False
        self._no_flow_elapsed = 0.0
        self._sensor_missed: dict[str, int] = {}
        self._faults: set[str] = set()
        self._alarms: dict[str, AlarmRecord] = {}
        self._audit: deque[AuditEvent] = deque(maxlen=self.AUDIT_SIZE)
        self._processed_requests: dict[str, dict[str, Any]] = {}
        self._valves: dict[str, dict[str, Any]] = {}
        self._pump: dict[str, Any] = {}
        self.tags = TagRegistry(history_size=self._history_size, now=self._timestamp)
        self._initialize_runtime()

    # ------------------------------------------------------------------
    # Public catalog and lifecycle interface
    # ------------------------------------------------------------------

    def snapshot(self) -> dict[str, Any]:
        """Return a detached JSON-ready complete state snapshot."""

        permissives = self._pump_start_permissives()
        interlocks = self._active_interlocks()
        equipment = self._equipment_snapshot(permissives, interlocks)
        active_alarms = [item.as_dict() for item in self._alarms.values() if item.active]
        alarm_history = [item.as_dict() for item in self._alarms.values()]
        events = [item.as_dict() for item in self._audit]
        return {
            "schemaVersion": self.SCHEMA_VERSION,
            "stateVersion": self._state_version,
            "emittedAt": _iso(self._timestamp),
            "system": {
                "name": "Oracle",
                "site": "NILIT",
                "processLine": "NILIT Line 1",
                "mode": self._mode.value,
                "state": self._line_state.value,
                "connected": self._plc_healthy(),
                "plc": "PLC-01 / SIMULATED",
                "scanMs": int(self.scan_interval * 1000),
                "simulation": True,
                "updatedAt": _iso(self._timestamp),
                "stateVersion": self._state_version,
                "sequence": self._auto_phase,
            },
            "tags": self.tags.snapshot(),
            "equipment": equipment,
            "permissives": [item.as_dict() for item in permissives],
            "interlocks": [item.as_dict() for item in interlocks],
            "alarms": active_alarms,
            "alarmHistory": alarm_history,
            "events": events,
            "faults": sorted(self._faults),
        }

    def tick(self, dt: float | None = None, *, now: datetime | None = None) -> dict[str, Any]:
        """Advance the simulator by one scan and return the new snapshot.

        ``dt`` defaults to the configured one-second scan.  It is bounded to
        five scan periods so a paused caller cannot create an unsafe process
        jump.  ``now`` is accepted for deterministic callers but simulated
        timestamps remain based on the controlled simulation clock.
        """

        elapsed = self.scan_interval if dt is None else float(dt)
        if elapsed <= 0:
            raise ValueError("tick dt must be greater than zero")
        elapsed = min(elapsed, self.scan_interval * 5.0)
        self._sim_seconds += elapsed
        self._timestamp = self._epoch + timedelta(seconds=self._sim_seconds)
        self._wall_last_tick = now or self._clock()

        self._apply_fault_inputs()
        self._advance_valves(elapsed)
        self._advance_pump(elapsed)
        self._calculate_process(elapsed)
        self._refresh_sensor_quality()
        self._evaluate_alarms()
        self._evaluate_hard_interlocks()
        self._advance_auto_sequence()
        self._state_version += 1
        return self.snapshot()

    def reset(
        self,
        *,
        actor: str | None = None,
        role: str = "supervisor",
        preserve_time: bool = False,
    ) -> dict[str, Any]:
        """Return the simulator to its safe initial state.

        A direct reset is intended for a backend lifecycle hook.  User-facing
        resets should normally use ``command("RESET_LINE", role="supervisor")``
        so the action is authorized and audited.
        """

        if not preserve_time:
            self._sim_seconds = 0.0
            self._timestamp = self._epoch
        self._initialize_runtime(clear_history=True)
        self._state_version += 1
        if actor:
            self._audit_event(
                "Simulator reset to safe initial state",
                actor=actor,
                role=role,
                action="RESET_LINE",
                source="simulator",
                result=CommandStatus.ACCEPTED.value,
            )
        return self.snapshot()

    def health(self) -> dict[str, Any]:
        """Return simulator/controller health without performing I/O."""

        wall_now = self._clock()
        age_ms = max(0, int((wall_now - self._wall_last_tick).total_seconds() * 1000))
        connected = self._plc_healthy()
        simulator_state = "RUNNING" if connected else "FAULT"
        return {
            "ok": connected,
            "service": "oracle-logic",
            "simulator": simulator_state,
            "connected": connected,
            "plc": "PLC-01 / SIMULATED",
            "scanIntervalMs": int(self.scan_interval * 1000),
            "scanAgeMs": age_ms,
            "stateVersion": self._state_version,
            "lineState": self._line_state.value,
            "mode": self._mode.value,
            "simulation": True,
            "externalWrites": False,
        }

    def tag_catalog(self) -> list[dict[str, Any]]:
        return tag_catalog()

    def equipment_catalog(self) -> list[dict[str, Any]]:
        return equipment_catalog()

    def catalogs(self) -> dict[str, list[dict[str, Any]]]:
        return {"tags": self.tag_catalog(), "equipment": self.equipment_catalog()}

    # ------------------------------------------------------------------
    # Command boundary
    # ------------------------------------------------------------------

    def command(
        self,
        action: str | Mapping[str, Any],
        *,
        actor: str = "operator",
        role: str = "operator",
        request_id: str | None = None,
        equipment_id: str | None = None,
        mode: str | Mode | None = None,
        alarm_id: str | None = None,
        expected_state_version: int | None = None,
        reason: str | None = None,
        **parameters: Any,
    ) -> dict[str, Any]:
        """Validate and execute a control command.

        The method accepts either a simple action string or a JSON-like
        mapping.  It supports the planned backend payloads (``action``,
        ``mode``, ``clientCommandId``) and the richer equipment payloads
        (``equipmentId``, ``command``, ``expectedStateVersion``).
        """

        payload: dict[str, Any] = dict(action) if isinstance(action, Mapping) else {}
        if payload:
            action_name = payload.get("action") or payload.get("command")
            actor = str(payload.get("actor", actor))
            role = str(payload.get("role", role))
            request_id = payload.get("requestId", payload.get("clientCommandId", request_id))
            equipment_id = payload.get("equipmentId", equipment_id)
            mode = payload.get("mode", mode)
            alarm_id = payload.get("alarmId", alarm_id)
            expected_state_version = payload.get("expectedStateVersion", expected_state_version)
            reason = payload.get("reason", reason)
            reserved = {
                "action", "command", "actor", "role", "requestId", "clientCommandId",
                "equipmentId", "mode", "alarmId", "expectedStateVersion", "reason", "parameters",
            }
            top_level_parameters = {key: value for key, value in payload.items() if key not in reserved}
            parameters = {**payload.get("parameters", {}), **top_level_parameters, **parameters}
        else:
            action_name = action
        if not action_name:
            return self._reject("", request_id, "INVALID_COMMAND", "A command action is required", actor, role)
        normalized = self._normalize_action(str(action_name))
        original_normalized = str(action_name).strip().upper().replace("-", "_").replace(" ", "_")
        if original_normalized in {"OPEN_INLET", "CLOSE_INLET", "OPEN_OUTLET", "CLOSE_OUTLET"}:
            parameters = {**parameters, "actionAlias": original_normalized}
        command_id = self._new_id("cmd")
        request_key = str(request_id) if request_id else None
        if request_key and request_key in self._processed_requests:
            return dict(self._processed_requests[request_key])

        if expected_state_version is not None:
            try:
                expected = int(expected_state_version)
            except (TypeError, ValueError):
                return self._reject(normalized, request_key, "INVALID_STATE_VERSION", "Expected state version must be an integer", actor, role, command_id)
            if expected != self._state_version:
                return self._reject(normalized, request_key, "STATE_VERSION_CONFLICT", f"Expected state version {expected}, current is {self._state_version}", actor, role, command_id)

        permitted_roles = {"operator", "supervisor"}
        role = role.lower()
        if role not in permitted_roles:
            return self._reject(normalized, request_key, "UNAUTHORIZED", "Unknown control role", actor, role, command_id)

        supervisor_actions = {"SET_MODE", "RESET_LINE", "RESET", "SET_SIM_CONFIG", "INJECT_FAULT", "CLEAR_FAULT"}
        if normalized in supervisor_actions and role != "supervisor":
            return self._reject(normalized, request_key, "UNAUTHORIZED", "Supervisor role is required for this command", actor, role, command_id)

        result = self._execute_command(
            normalized,
            command_id=command_id,
            request_id=request_key,
            actor=actor,
            role=role,
            equipment_id=equipment_id,
            mode=mode,
            alarm_id=alarm_id,
            reason=reason,
            parameters=parameters,
        )
        if request_key:
            self._processed_requests[request_key] = dict(result)
            if len(self._processed_requests) > 500:
                self._processed_requests.pop(next(iter(self._processed_requests)))
        return result

    # ------------------------------------------------------------------
    # Command implementation
    # ------------------------------------------------------------------

    def _execute_command(
        self,
        action: str,
        *,
        command_id: str,
        request_id: str | None,
        actor: str,
        role: str,
        equipment_id: str | None,
        mode: str | Mode | None,
        alarm_id: str | None,
        reason: str | None,
        parameters: Mapping[str, Any],
    ) -> dict[str, Any]:
        if action in {"START_LINE", "STOP_LINE", "RESET_LINE"}:
            if action == "START_LINE":
                if self._mode != Mode.AUTO:
                    return self._reject(action, request_id, "WRONG_MODE", "START_LINE requires AUTO mode", actor, role, command_id)
                if self._active_interlocks():
                    return self._reject(action, request_id, "INTERLOCK_ACTIVE", "Line start is blocked by an active interlock", actor, role, command_id)
                self._auto_requested = True
                self._auto_phase = "OPENING"
                self._line_state = LineState.STARTING
                self._command_valve("XV-101", True)
                self._command_valve("XV-102", True)
                return self._accept(action, request_id, command_id, actor, role, "AUTO start sequence requested", self._line_state.value)
            if action == "STOP_LINE":
                self._auto_requested = False
                self._auto_phase = "STOPPING"
                self._close_after_stop = True
                self._stop_pump()
                if self._pump["state"] == PumpState.STOPPED:
                    self._force_close_valves()
                    self._line_state = LineState.STOPPED
                    self._auto_phase = "IDLE"
                else:
                    self._line_state = LineState.STOPPING
                return self._accept(action, request_id, command_id, actor, role, "AUTO stop sequence requested", self._line_state.value)
            if action == "RESET_LINE":
                return self._reset_line_command(action, request_id, command_id, actor, role)

        if action in {"START", "START_PUMP"}:
            if self._mode == Mode.AUTO:
                return self._reject(action, request_id, "AUTO_CONTROL_OWNER", "Direct pump start is owned by the AUTO sequence", actor, role, command_id)
            return self._start_command(action, request_id, command_id, actor, role)

        if action in {"STOP", "STOP_PUMP"}:
            self._close_after_stop = True
            self._stop_pump()
            if self._pump["state"] == PumpState.STOPPED:
                self._force_close_valves()
                self._line_state = LineState.STOPPED
            else:
                self._line_state = LineState.STOPPING
            return self._accept(action, request_id, command_id, actor, role, "Pump stop requested", self._line_state.value)

        if action in {"OPEN", "CLOSE"}:
            target = (equipment_id or parameters.get("target") or parameters.get("valveId") or "").upper()
            if not target and parameters.get("actionAlias") in {"OPEN_INLET", "CLOSE_INLET"}:
                target = "XV-101"
            if not target and parameters.get("actionAlias") in {"OPEN_OUTLET", "CLOSE_OUTLET"}:
                target = "XV-102"
            if target not in self._valves:
                return self._reject(action, request_id, "UNKNOWN_EQUIPMENT", "An XV-101 or XV-102 equipmentId is required", actor, role, command_id)
            if self._mode == Mode.AUTO:
                return self._reject(action, request_id, "AUTO_CONTROL_OWNER", "Direct valve commands are owned by the AUTO sequence", actor, role, command_id)
            if action == "CLOSE" and self._pump["state"] in {PumpState.STARTING, PumpState.RUNNING}:
                return self._reject(action, request_id, "PUMP_RUNNING", f"{target} cannot close while P-101 is running", actor, role, command_id, equipment_id=target)
            changed = self._command_valve(target, action == "OPEN")
            if not changed:
                return self._accept(action, request_id, command_id, actor, role, f"{target} already in the requested state", self._valves[target]["state"].value, equipment_id=target, status=CommandStatus.NOOP)
            return self._accept(action, request_id, command_id, actor, role, f"{target} {action.lower()} command accepted", self._valves[target]["state"].value, equipment_id=target)

        if action in {"SET_MODE", "MODE"}:
            desired = str(mode or parameters.get("mode") or "").upper()
            if desired not in {Mode.AUTO.value, Mode.MANUAL.value}:
                return self._reject(action, request_id, "INVALID_MODE", "Mode must be AUTO or MANUAL", actor, role, command_id)
            if self._pump["state"] not in {PumpState.STOPPED, PumpState.FAULT, PumpState.TRIPPED} or self._line_state in {LineState.RUNNING, LineState.STARTING}:
                return self._reject(action, request_id, "LINE_RUNNING", "Mode can only change while the line is stopped", actor, role, command_id)
            if self._active_interlocks() and desired == Mode.AUTO.value:
                return self._reject(action, request_id, "INTERLOCK_ACTIVE", "AUTO mode is blocked by an active interlock", actor, role, command_id)
            self._mode = Mode(desired)
            self._auto_phase = "IDLE"
            return self._accept(action, request_id, command_id, actor, role, f"Mode changed to {desired}", self._line_state.value)

        if action in {"ACK_ALL", "ACKNOWLEDGE_ALL"}:
            count = self._acknowledge_all(actor, role)
            status = CommandStatus.ACCEPTED if count else CommandStatus.NOOP
            return self._accept(action, request_id, command_id, actor, role, f"Acknowledged {count} active alarm(s)", self._line_state.value, status=status)

        if action in {"ACK_ALARM", "ACKNOWLEDGE_ALARM"}:
            target = alarm_id or parameters.get("alarmId") or parameters.get("id")
            if not target or target not in self._alarms or not self._alarms[target].active:
                return self._reject(action, request_id, "UNKNOWN_ALARM", "Active alarmId is required", actor, role, command_id)
            self._acknowledge_alarm(str(target), actor, role)
            return self._accept(action, request_id, command_id, actor, role, f"Alarm {target} acknowledged", self._line_state.value)

        if action in {"RESET", "RESET_PUMP"}:
            if self._pump["state"] not in {PumpState.TRIPPED, PumpState.FAULT}:
                return self._accept(action, request_id, command_id, actor, role, "No pump fault was latched", self._line_state.value, status=CommandStatus.NOOP)
            if self._active_interlocks():
                return self._reject(action, request_id, "INTERLOCK_ACTIVE", "The initiating interlock must clear before reset", actor, role, command_id)
            self._pump["state"] = PumpState.STOPPED
            self._pump["active_fault"] = None
            self._line_state = LineState.STOPPED
            self._auto_phase = "IDLE"
            self._clear_latched_trip_alarms()
            self._audit_event("Pump trip reset", actor=actor, role=role, action=action, equipment_id="P-101", result=CommandStatus.ACCEPTED.value, command_id=command_id)
            return self._accept(action, request_id, command_id, actor, role, "Pump trip reset", self._line_state.value)

        if action == "SET_SIM_CONFIG":
            if "noiseScale" not in parameters and "noise_scale" not in parameters:
                return self._reject(action, request_id, "INVALID_PARAMETER", "noiseScale is required", actor, role, command_id)
            value = parameters.get("noiseScale", parameters.get("noise_scale"))
            try:
                value = float(value)
            except (TypeError, ValueError):
                return self._reject(action, request_id, "INVALID_PARAMETER", "noiseScale must be numeric", actor, role, command_id)
            if not 0 <= value <= 2:
                return self._reject(action, request_id, "INVALID_PARAMETER", "noiseScale must be between 0 and 2", actor, role, command_id)
            self._noise_scale = value
            return self._accept(action, request_id, command_id, actor, role, f"Noise scale set to {value}", self._line_state.value)

        if action in {"INJECT_FAULT", "CLEAR_FAULT"}:
            fault = str(parameters.get("fault") or parameters.get("faultId") or "").lower().replace("_", "-")
            allowed = {"stuck-xv-101", "stuck-xv-102", "fail-to-start", "no-flow", "esd", "plc-loss", "bad-lits", "bad-pressure", "stale-level"}
            if fault not in allowed:
                return self._reject(action, request_id, "INVALID_FAULT", f"Fault must be one of: {', '.join(sorted(allowed))}", actor, role, command_id)
            if action == "INJECT_FAULT":
                self._faults.add(fault)
                message = f"Simulation fault injected: {fault}"
            else:
                self._faults.discard(fault)
                message = f"Simulation fault cleared: {fault}"
            self._audit_event(message, actor=actor, role=role, action=action, source="simulator", result=CommandStatus.ACCEPTED.value, command_id=command_id, severity=Severity.WARNING if action == "INJECT_FAULT" else Severity.INFO)
            return self._accept(action, request_id, command_id, actor, role, message, self._line_state.value)

        return self._reject(action, request_id, "UNSUPPORTED_COMMAND", f"Unsupported command: {action}", actor, role, command_id)

    # ------------------------------------------------------------------
    # Runtime transitions
    # ------------------------------------------------------------------

    def _initialize_runtime(self, *, clear_history: bool = False) -> None:
        self._mode = Mode.MANUAL
        self._line_state = LineState.STOPPED
        self._auto_phase = "IDLE"
        self._auto_requested = False
        self._close_after_stop = False
        self._no_flow_elapsed = 0.0
        self._sensor_missed.clear()
        self._faults.clear()
        self._valves = {
            "XV-101": {"state": ValveState.CLOSED, "commanded": ValveState.CLOSED, "timer": 0.0, "active_fault": None},
            "XV-102": {"state": ValveState.CLOSED, "commanded": ValveState.CLOSED, "timer": 0.0, "active_fault": None},
        }
        self._pump = {
            "state": PumpState.STOPPED,
            "commanded": PumpState.STOPPED,
            "timer": 0.0,
            "active_fault": None,
        }
        self.tags.reset(now=self._timestamp)
        self.tags.update_many(
            {
                "P-101.run": False,
                "M-101.run": False,
                "XV-101.open": False,
                "XV-102.open": False,
                "FT-101.flow": 0.0,
                "PT-101.pressure": 0.0,
                "ESD-001.active": False,
                "PLC-01.healthy": True,
            },
            timestamp=self._timestamp,
        )
        if clear_history:
            self._alarms.clear()
            self._audit.clear()
            self._processed_requests.clear()
        self._evaluate_alarms()

    def _advance_valves(self, dt: float) -> None:
        for equipment_id, valve in self._valves.items():
            commanded = valve["commanded"]
            state = valve["state"]
            if state == ValveState.FAULT:
                continue
            if commanded == ValveState.OPEN and state != ValveState.OPEN:
                if state != ValveState.OPENING:
                    valve["state"] = ValveState.OPENING
                    valve["timer"] = 0.0
                valve["timer"] += dt
                if "stuck-" + equipment_id.lower() not in self._faults and valve["timer"] >= self.VALVE_TRAVEL_SECONDS:
                    valve["state"] = ValveState.OPEN
                    valve["timer"] = 0.0
                    self._audit_event(f"{equipment_id} reached OPEN feedback", source="simulator", equipment_id=equipment_id)
                elif valve["timer"] >= self.VALVE_TIMEOUT_SECONDS:
                    valve["state"] = ValveState.FAULT
                    valve["active_fault"] = "VALVE_TRAVEL_TIMEOUT"
            elif commanded == ValveState.CLOSED and state != ValveState.CLOSED:
                if state != ValveState.CLOSING:
                    valve["state"] = ValveState.CLOSING
                    valve["timer"] = 0.0
                valve["timer"] += dt
                if "stuck-" + equipment_id.lower() not in self._faults and valve["timer"] >= self.VALVE_TRAVEL_SECONDS:
                    valve["state"] = ValveState.CLOSED
                    valve["timer"] = 0.0
                    self._audit_event(f"{equipment_id} reached CLOSED feedback", source="simulator", equipment_id=equipment_id)
                elif valve["timer"] >= self.VALVE_TIMEOUT_SECONDS:
                    valve["state"] = ValveState.FAULT
                    valve["active_fault"] = "VALVE_TRAVEL_TIMEOUT"
            self.tags.set(f"{equipment_id}.open", valve["state"] == ValveState.OPEN, timestamp=self._timestamp)

    def _advance_pump(self, dt: float) -> None:
        state = self._pump["state"]
        if state == PumpState.STARTING:
            self._pump["timer"] += dt
            if "fail-to-start" in self._faults and self._pump["timer"] >= self.MOTOR_START_TIMEOUT_SECONDS:
                self._pump["state"] = PumpState.FAULT
                self._pump["active_fault"] = "PUMP_FAIL_TO_START"
                self._line_state = LineState.FAULT
                self._activate_alarm("P101-FAIL-START", "P-101", "P-101 failed to start", Severity.HIGH)
                self._force_close_valves()
                self._audit_event("P-101 failed to start", source="control", equipment_id="P-101", severity=Severity.HIGH, result=CommandStatus.FAILED.value, reason_code="PUMP_FAIL_TO_START")
            elif self._pump["timer"] >= self.MOTOR_START_SECONDS:
                self._pump["state"] = PumpState.RUNNING
                self._pump["timer"] = 0.0
                self._line_state = LineState.RUNNING
                self._auto_phase = "RUNNING" if self._mode == Mode.AUTO else self._auto_phase
                self._audit_event("P-101 run feedback received", source="simulator", equipment_id="P-101")
        elif state == PumpState.STOPPING:
            self._pump["timer"] += dt
            if self._pump["timer"] >= 1.0:
                self._pump["state"] = PumpState.STOPPED
                self._pump["timer"] = 0.0
                self._pump["active_fault"] = None
                self._line_state = LineState.STOPPED
                if self._close_after_stop:
                    self._force_close_valves()
                    self._close_after_stop = False
                self._audit_event("P-101 stopped", source="simulator", equipment_id="P-101")
        run_feedback = self._pump["state"] == PumpState.RUNNING
        self.tags.set("P-101.run", run_feedback, timestamp=self._timestamp)
        self.tags.set("M-101.run", run_feedback, timestamp=self._timestamp)

    def _calculate_process(self, dt: float) -> None:
        running = self._pump["state"] == PumpState.RUNNING
        inlet_open = self._valves["XV-101"]["state"] == ValveState.OPEN
        outlet_open = self._valves["XV-102"]["state"] == ValveState.OPEN
        if running and inlet_open and outlet_open and "no-flow" not in self._faults:
            flow = max(0.0, min(200.0, 126.0 + math.sin(self._sim_seconds / 12.0) * 9.0 + self._noise(4.0)))
        else:
            flow = 0.0
        pressure = 0.0 if not running else max(0.0, min(8.0, 4.15 + flow / 140.0 * 0.35 + self._noise(0.12)))
        feed_level = float(self.tags.get("TK-101.level"))
        receiving_level = float(self.tags.get("TK-102.level"))
        feed_change = (0.24 if inlet_open else -0.16) - (0.34 if running else 0.0)
        receiving_change = (0.18 if running else -0.05)
        feed_level = max(0.0, min(100.0, feed_level + dt * feed_change + self._noise(0.12)))
        receiving_level = max(0.0, min(100.0, receiving_level + dt * receiving_change + self._noise(0.08)))
        ph = float(self.tags.get("AIT-101.ph"))
        temperature = float(self.tags.get("TT-101.temperature"))
        ph = max(0.0, min(14.0, ph + math.sin(self._sim_seconds / 35.0) * 0.008 * dt + self._noise(0.018)))
        temperature = max(0.0, min(80.0, temperature + math.sin(self._sim_seconds / 40.0) * 0.02 * dt + self._noise(0.03)))
        self.tags.update_many(
            {
                "TK-101.level": feed_level,
                "TK-102.level": receiving_level,
                "FT-101.flow": flow,
                "PT-101.pressure": pressure,
                "AIT-101.ph": ph,
                "TT-101.temperature": temperature,
                "ESD-001.active": "esd" in self._faults,
                "PLC-01.healthy": "plc-loss" not in self._faults,
            },
            timestamp=self._timestamp,
        )
        if running and flow < 10.0:
            self._no_flow_elapsed += dt
        else:
            self._no_flow_elapsed = 0.0

    def _refresh_sensor_quality(self) -> None:
        plc_quality = Quality.BAD if "plc-loss" in self._faults else Quality.GOOD
        for tag_id in ("LIT-101.level", "LIT-102.level", "FT-101.flow", "PT-101.pressure", "AIT-101.ph", "TT-101.temperature"):
            quality = plc_quality
            if tag_id in {"LIT-101.level", "LIT-102.level"} and ("bad-lits" in self._faults or "stale-level" in self._faults):
                quality = Quality.STALE if "stale-level" in self._faults else Quality.BAD
            if tag_id == "PT-101.pressure" and "bad-pressure" in self._faults:
                quality = Quality.BAD
            self.tags.set_quality(tag_id, quality, timestamp=self._timestamp)

    def _apply_fault_inputs(self) -> None:
        if "esd" in self._faults and self._line_state != LineState.E_STOPPED:
            self._line_state = LineState.E_STOPPED
        if "plc-loss" in self._faults:
            self.tags.set("PLC-01.healthy", False, timestamp=self._timestamp, quality=Quality.BAD)

    def _advance_auto_sequence(self) -> None:
        if self._mode != Mode.AUTO:
            return
        if self._auto_requested and self._auto_phase == "OPENING":
            if self._valves_open():
                if self._start_pump_internal():
                    self._auto_phase = "STARTING"
        elif self._auto_requested and self._auto_phase == "STARTING" and self._pump["state"] == PumpState.RUNNING:
            self._auto_phase = "RUNNING"
        elif not self._auto_requested and self._auto_phase == "STOPPING" and self._pump["state"] == PumpState.STOPPED:
            self._force_close_valves()
            self._auto_phase = "IDLE"
            self._line_state = LineState.STOPPED

    # ------------------------------------------------------------------
    # Permissives, interlocks, alarms, and audit
    # ------------------------------------------------------------------

    def _pump_start_permissives(self) -> list[Permissive]:
        return [
            Permissive("ESD_CLEAR", not bool(self.tags.get("ESD-001.active")), "ESD-001 is clear"),
            Permissive("PLC_HEALTHY", self._plc_healthy(), "PLC-01 simulator health is good"),
            Permissive("CRITICAL_SIGNALS_GOOD", self._critical_signals_good(), "Required feedback signals are GOOD"),
            Permissive("TK101_SAFE", float(self.tags.get("TK-101.level")) > 15.0, "TK-101 level is above low-low"),
            Permissive("TK102_SAFE", float(self.tags.get("TK-102.level")) < 95.0, "TK-102 level is below high-high"),
            Permissive("XV101_OPEN", self._valves["XV-101"]["state"] == ValveState.OPEN, "XV-101 inlet is open"),
            Permissive("XV102_OPEN", self._valves["XV-102"]["state"] == ValveState.OPEN, "XV-102 outlet is open"),
            Permissive("NO_EQUIPMENT_TRIP", self._pump["state"] not in {PumpState.TRIPPED, PumpState.FAULT} and all(item["state"] != ValveState.FAULT for item in self._valves.values()), "No equipment trip is latched"),
        ]

    def _active_interlocks(self) -> list[Interlock]:
        conditions = [
            Interlock("ESD_ACTIVE", bool(self.tags.get("ESD-001.active")), "ESD-001 is active"),
            Interlock("TK101_LOW_LOW", float(self.tags.get("TK-101.level")) <= 15.0, "TK-101 is at or below low-low"),
            Interlock("TK102_HIGH_HIGH", float(self.tags.get("TK-102.level")) >= 95.0, "TK-102 is at or above high-high"),
            Interlock("PT101_HIGH_HIGH", float(self.tags.get("PT-101.pressure")) >= 7.0, "PT-101 pressure is at or above high-high"),
            Interlock("CRITICAL_SIGNAL_BAD", not self._critical_signals_good(), "A critical control signal is not GOOD"),
            Interlock("PUMP_NO_FLOW", self._pump["state"] == PumpState.RUNNING and self._no_flow_elapsed >= self.NO_FLOW_SECONDS, "P-101 has no flow while running"),
            Interlock("VALVE_FAULT", any(item["state"] == ValveState.FAULT for item in self._valves.values()), "A process valve is faulted"),
        ]
        return [item for item in conditions if item.active]

    def _evaluate_hard_interlocks(self) -> None:
        active = self._active_interlocks()
        if not active:
            return
        trip = next((item for item in active if item.id in {"ESD_ACTIVE", "TK101_LOW_LOW", "TK102_HIGH_HIGH", "PT101_HIGH_HIGH", "CRITICAL_SIGNAL_BAD", "PUMP_NO_FLOW", "VALVE_FAULT"}), None)
        if trip and self._pump["state"] in {PumpState.STARTING, PumpState.RUNNING}:
            self._trip(trip.id, trip.message)
        elif trip and trip.id == "ESD_ACTIVE":
            self._line_state = LineState.E_STOPPED
            self._force_close_valves()

    def _evaluate_alarms(self) -> None:
        checks = [
            ("TK101-LOW", "TK-101", "TK-101 level low", Severity.WARNING, float(self.tags.get("TK-101.level")) < 30.0),
            ("TK101-LOW-LOW", "TK-101", "TK-101 level low-low", Severity.HIGH, float(self.tags.get("TK-101.level")) <= 15.0),
            ("TK102-HIGH", "TK-102", "TK-102 level high", Severity.WARNING, float(self.tags.get("TK-102.level")) > 85.0),
            ("TK102-HIGH-HIGH", "TK-102", "TK-102 level high-high", Severity.HIGH, float(self.tags.get("TK-102.level")) >= 95.0),
            ("AIT101-PH", "AIT-101", "AIT-101 pH outside 6.5–8.5", Severity.WARNING, not 6.5 <= float(self.tags.get("AIT-101.ph")) <= 8.5),
            ("PT101-HIGH", "PT-101", "PT-101 pressure high", Severity.WARNING, float(self.tags.get("PT-101.pressure")) > 5.5),
            ("PT101-HIGH-HIGH", "PT-101", "PT-101 pressure high-high", Severity.HIGH, float(self.tags.get("PT-101.pressure")) >= 7.0),
            ("TT101-HIGH", "TT-101", "TT-101 temperature high", Severity.WARNING, float(self.tags.get("TT-101.temperature")) > 70.0),
            ("P101-NO-FLOW", "P-101", "P-101 no-flow while running", Severity.HIGH, self._pump["state"] == PumpState.RUNNING and self._no_flow_elapsed >= self.NO_FLOW_SECONDS),
            ("ESD-001-ACTIVE", "ESD-001", "Emergency stop ESD-001 is active", Severity.HIGH, bool(self.tags.get("ESD-001.active"))),
            ("PLC-01-LOSS", "PLC-01", "PLC-01 simulator communication is unhealthy", Severity.HIGH, not self._plc_healthy()),
            ("LIT-SIGNAL-BAD", "LIT-101/LIT-102", "A level signal is BAD or STALE", Severity.HIGH, not self._critical_signals_good()),
        ]
        for alarm_id, source, message, severity, active in checks:
            if active:
                self._activate_alarm(alarm_id, source, message, severity)
            else:
                self._clear_alarm(alarm_id)
        if self._pump["active_fault"]:
            self._activate_alarm("P101-FAULT", "P-101", self._pump["active_fault"], Severity.HIGH)
        else:
            self._clear_alarm("P101-FAULT")
        for equipment_id, valve in self._valves.items():
            alarm_id = f"{equipment_id}-FAULT"
            if valve["active_fault"]:
                self._activate_alarm(alarm_id, equipment_id, f"{equipment_id} {valve['active_fault']}", Severity.HIGH)
            else:
                self._clear_alarm(alarm_id)

    def _activate_alarm(self, alarm_id: str, source: str, message: str, severity: Severity) -> None:
        current = self._alarms.get(alarm_id)
        if current and current.active:
            current.last_changed_at = _iso(self._timestamp)
            return
        count = (current.activation_count + 1) if current else 1
        alarm = AlarmRecord(
            id=alarm_id,
            source=source,
            message=message,
            severity=severity,
            active=True,
            acknowledged=False,
            since=_iso(self._timestamp),
            last_changed_at=_iso(self._timestamp),
            activation_count=count,
        )
        self._alarms[alarm_id] = alarm
        self._audit_event(f"Alarm active: {message}", source="alarm", severity=severity, related_alarm_id=alarm_id)

    def _clear_alarm(self, alarm_id: str) -> None:
        current = self._alarms.get(alarm_id)
        if not current or not current.active:
            return
        current.active = False
        current.cleared_at = _iso(self._timestamp)
        current.last_changed_at = _iso(self._timestamp)
        self._audit_event(f"Alarm cleared: {current.message}", source="alarm", severity=Severity.INFO, related_alarm_id=alarm_id)

    def _acknowledge_alarm(self, alarm_id: str, actor: str, role: str) -> None:
        alarm = self._alarms[alarm_id]
        if not alarm.active or alarm.acknowledged:
            return
        alarm.acknowledged = True
        alarm.acknowledged_at = _iso(self._timestamp)
        alarm.acknowledged_by = actor
        alarm.last_changed_at = _iso(self._timestamp)
        self._audit_event(f"Alarm acknowledged: {alarm.message}", actor=actor, role=role, action="ACK_ALARM", source="alarm", related_alarm_id=alarm_id)

    def _acknowledge_all(self, actor: str, role: str) -> int:
        count = 0
        for alarm_id, alarm in self._alarms.items():
            if alarm.active and not alarm.acknowledged:
                self._acknowledge_alarm(alarm_id, actor, role)
                count += 1
        return count

    def _trip(self, cause: str, message: str) -> None:
        if self._pump["state"] in {PumpState.TRIPPED, PumpState.FAULT} and self._pump["active_fault"] == cause:
            return
        self._pump["state"] = PumpState.TRIPPED
        self._pump["commanded"] = PumpState.STOPPED
        self._pump["timer"] = 0.0
        self._pump["active_fault"] = cause
        self._line_state = LineState.E_STOPPED if cause == "ESD_ACTIVE" else LineState.TRIPPED
        self._auto_requested = False
        self._auto_phase = "TRIPPED"
        self._close_after_stop = False
        self._force_close_valves()
        self._activate_alarm(f"TRIP-{cause}", "P-101", f"P-101 tripped: {message}", Severity.HIGH)
        self._audit_event(f"P-101 hard trip: {message}", source="control", equipment_id="P-101", severity=Severity.HIGH, result=CommandStatus.FAILED.value, reason_code=cause)

    def _audit_event(
        self,
        message: str,
        *,
        source: str = "control",
        severity: Severity = Severity.INFO,
        actor: str | None = None,
        role: str | None = None,
        action: str | None = None,
        equipment_id: str | None = None,
        result: str | None = None,
        reason_code: str | None = None,
        command_id: str | None = None,
        related_alarm_id: str | None = None,
    ) -> None:
        self._audit.append(
            AuditEvent(
                id=self._new_id("evt"),
                time=_iso(self._timestamp),
                source=source,
                message=message,
                severity=severity,
                actor=actor,
                role=role,
                action=action,
                equipment_id=equipment_id,
                result=result,
                reason_code=reason_code,
                command_id=command_id,
                state_version=self._state_version,
                related_alarm_id=related_alarm_id,
            )
        )

    # ------------------------------------------------------------------
    # Helpers and JSON-ready command results
    # ------------------------------------------------------------------

    def _start_command(self, action: str, request_id: str | None, command_id: str, actor: str, role: str) -> dict[str, Any]:
        if self._pump["state"] == PumpState.RUNNING or self._pump["state"] == PumpState.STARTING:
            return self._accept(action, request_id, command_id, actor, role, "P-101 is already starting or running", self._line_state.value, status=CommandStatus.NOOP)
        if self._pump["state"] in {PumpState.TRIPPED, PumpState.FAULT}:
            return self._reject(action, request_id, "TRIP_LATCHED", "P-101 has a latched trip or fault; reset is required", actor, role, command_id)
        failed = next((item for item in self._pump_start_permissives() if not item.ok), None)
        if failed:
            return self._reject(action, request_id, "PERMISSIVE_NOT_MET", failed.message, actor, role, command_id, equipment_id="P-101")
        self._start_pump_internal()
        return self._accept(action, request_id, command_id, actor, role, "P-101 start accepted", self._line_state.value, equipment_id="P-101")

    def _start_pump_internal(self) -> bool:
        failed = next((item for item in self._pump_start_permissives() if not item.ok), None)
        if failed:
            return False
        if self._pump["state"] in {PumpState.RUNNING, PumpState.STARTING}:
            return True
        self._pump["state"] = PumpState.STARTING
        self._pump["commanded"] = PumpState.RUNNING
        self._pump["timer"] = 0.0
        self._line_state = LineState.STARTING
        self._audit_event("P-101 start transition begun", source="control", equipment_id="P-101")
        return True

    def _stop_pump(self) -> None:
        if self._pump["state"] in {PumpState.STOPPED, PumpState.STOPPING}:
            return
        if self._pump["state"] in {PumpState.TRIPPED, PumpState.FAULT}:
            self._force_close_valves()
            return
        self._pump["state"] = PumpState.STOPPING
        self._pump["commanded"] = PumpState.STOPPED
        self._pump["timer"] = 0.0

    def _command_valve(self, equipment_id: str, open_state: bool, *, force: bool = False) -> bool:
        valve = self._valves[equipment_id]
        desired = ValveState.OPEN if open_state else ValveState.CLOSED
        if not force and not open_state and self._pump["state"] in {PumpState.STARTING, PumpState.RUNNING}:
            return False
        if valve["state"] == desired and valve["commanded"] == desired:
            return False
        valve["commanded"] = desired
        if valve["state"] != desired:
            valve["state"] = ValveState.OPENING if open_state else ValveState.CLOSING
            valve["timer"] = 0.0
        return True

    def _force_close_valves(self) -> None:
        for equipment_id in self._valves:
            self._command_valve(equipment_id, False, force=True)

    def _valves_open(self) -> bool:
        return all(self._valves[item]["state"] == ValveState.OPEN for item in ("XV-101", "XV-102"))

    def _critical_signals_good(self) -> bool:
        required = ("LIT-101.level", "LIT-102.level", "FT-101.flow", "PT-101.pressure")
        return all(self.tags.quality(item) == Quality.GOOD for item in required)

    def _plc_healthy(self) -> bool:
        return "plc-loss" not in self._faults and self.tags.quality("PLC-01.healthy") == Quality.GOOD and bool(self.tags.get("PLC-01.healthy"))

    def _noise(self, amplitude: float) -> float:
        if not self._noise_scale:
            return 0.0
        return self._rng.uniform(-amplitude, amplitude) * self._noise_scale

    def _reset_line_command(self, action: str, request_id: str | None, command_id: str, actor: str, role: str) -> dict[str, Any]:
        if self._active_interlocks():
            return self._reject(action, request_id, "INTERLOCK_ACTIVE", "The initiating interlock must clear before reset", actor, role, command_id)
        self._pump["state"] = PumpState.STOPPED
        self._pump["commanded"] = PumpState.STOPPED
        self._pump["active_fault"] = None
        self._pump["timer"] = 0.0
        self._line_state = LineState.STOPPED
        self._auto_requested = False
        self._auto_phase = "IDLE"
        self._force_close_valves()
        self._clear_latched_trip_alarms()
        self._audit_event("Line trip reset", actor=actor, role=role, action=action, source="control", result=CommandStatus.ACCEPTED.value, command_id=command_id)
        return self._accept(action, request_id, command_id, actor, role, "Line reset accepted; valves are closing", self._line_state.value)

    def _clear_latched_trip_alarms(self) -> None:
        for alarm_id in list(self._alarms):
            if alarm_id.startswith("TRIP-") or alarm_id in {"P101-FAIL-START", "P101-FAULT"}:
                self._clear_alarm(alarm_id)

    def _accept(
        self,
        action: str,
        request_id: str | None,
        command_id: str,
        actor: str,
        role: str,
        message: str,
        resulting_state: str | None,
        *,
        equipment_id: str | None = None,
        status: CommandStatus = CommandStatus.ACCEPTED,
    ) -> dict[str, Any]:
        self._state_version += 1
        self._audit_event(message, actor=actor, role=role, action=action, equipment_id=equipment_id, result=status.value, command_id=command_id)
        return CommandResult(True, status, action, command_id, request_id, self._state_version, message=message, resulting_state=resulting_state).as_dict()

    def _reject(
        self,
        action: str,
        request_id: str | None,
        reason_code: str,
        message: str,
        actor: str,
        role: str,
        command_id: str | None = None,
        *,
        equipment_id: str | None = None,
    ) -> dict[str, Any]:
        command_id = command_id or self._new_id("cmd")
        self._audit_event(message, actor=actor, role=role, action=action, equipment_id=equipment_id, result=CommandStatus.REJECTED.value, reason_code=reason_code, command_id=command_id, severity=Severity.WARNING)
        return CommandResult(False, CommandStatus.REJECTED, action, command_id, request_id, self._state_version, reason=message, reason_code=reason_code, message=message, resulting_state=self._line_state.value).as_dict()

    def _reset_state_without_replacing_object(self) -> None:
        self._initialize_runtime(clear_history=True)

    def _normalize_action(self, action: str) -> str:
        normalized = action.strip().upper().replace("-", "_").replace(" ", "_")
        aliases = {
            "START_P101": "START",
            "STOP_P101": "STOP",
            "OPEN_INLET": "OPEN",
            "CLOSE_INLET": "CLOSE",
            "OPEN_OUTLET": "OPEN",
            "CLOSE_OUTLET": "CLOSE",
            "ACK_ALL_ALARMS": "ACK_ALL",
            "SET_MODE": "SET_MODE",
            "RESET_SIMULATOR": "RESET_LINE",
            "SET_SIM_CONFIG": "SET_SIM_CONFIG",
            "INJECT_SIM_FAULT": "INJECT_FAULT",
            "CLEAR_SIM_FAULT": "CLEAR_FAULT",
        }
        return aliases.get(normalized, normalized)

    def _new_id(self, prefix: str) -> str:
        self._id_counter += 1
        return f"{prefix}-{self._id_counter:06d}"

    def _equipment_snapshot(self, permissives: list[Permissive], interlocks: list[Interlock]) -> dict[str, dict[str, Any]]:
        result: dict[str, dict[str, Any]] = {}
        for metadata in EQUIPMENT_CATALOG:
            item_id = metadata.id
            if item_id in self._valves:
                valve = self._valves[item_id]
                result[item_id] = EquipmentStatus(
                    item_id, metadata.type, valve["state"].value, self._mode,
                    valve["commanded"].value, valve["state"].value,
                    valve["state"] not in {ValveState.FAULT, ValveState.UNKNOWN},
                    active_fault=valve["active_fault"], state_version=self._state_version,
                ).as_dict()
            elif item_id in {"P-101", "M-101"}:
                result[item_id] = EquipmentStatus(
                    item_id, metadata.type, self._pump["state"].value, self._mode,
                    self._pump["commanded"].value, self._pump["state"].value,
                    self._pump["state"] not in {PumpState.FAULT, PumpState.TRIPPED, PumpState.UNKNOWN},
                    permissives=list(permissives) if item_id == "P-101" else [],
                    interlocks=list(interlocks) if item_id == "P-101" else [],
                    active_fault=self._pump["active_fault"], state_version=self._state_version,
                ).as_dict()
            elif item_id in {"TK-101", "TK-102"}:
                level = float(self.tags.get(f"{item_id}.level"))
                tank_state = "LOW_LOW" if level <= 15 else "LOW" if level < 30 else "HIGH_HIGH" if level >= 95 else "HIGH" if level > 85 else "NORMAL"
                result[item_id] = EquipmentStatus(
                    item_id, metadata.type, tank_state, self._mode, tank_state, tank_state,
                    self.tags.quality(f"{item_id}.level") == Quality.GOOD,
                    state_version=self._state_version,
                ).as_dict()
            elif item_id in {"LIT-101", "LIT-102", "FT-101", "PT-101", "AIT-101", "TT-101"}:
                tag_id = metadata.tags[0]
                quality = self.tags.quality(tag_id)
                state = "NORMAL" if quality == Quality.GOOD else quality.value
                result[item_id] = EquipmentStatus(
                    item_id, metadata.type, state, self._mode, state, state,
                    quality == Quality.GOOD, state_version=self._state_version,
                ).as_dict()
            elif item_id == "ESD-001":
                state = "ACTIVE" if self.tags.get("ESD-001.active") else "CLEAR"
                result[item_id] = EquipmentStatus(item_id, metadata.type, state, self._mode, state, state, state == "CLEAR", state_version=self._state_version).as_dict()
            elif item_id == "PLC-01":
                state = "HEALTHY" if self._plc_healthy() else "FAULT"
                result[item_id] = EquipmentStatus(item_id, metadata.type, state, self._mode, state, state, state == "HEALTHY", state_version=self._state_version).as_dict()
        return result


# Friendly aliases for backends that prefer a generic engine name.
ControlLogic = OracleLine1Logic
Line1Logic = OracleLine1Logic
