"""Public Oracle HTTP and state models.

The models accept Python field names and emit the approved camelCase wire
format.  A few optional fields preserve the richer equipment/control metadata
provided by ``oracle.logic`` while keeping the original HMI contract stable.
"""

from __future__ import annotations

import json
from datetime import datetime, timezone
from typing import Any, Dict, List, Literal, Optional, Union

from pydantic import BaseModel, ConfigDict, Field, StrictBool, StrictFloat


Role = Literal["operator", "supervisor"]
Mode = Literal["AUTO", "MANUAL"]
ProcessState = Literal["RUNNING", "STOPPED", "FAULT", "STARTING", "STOPPING", "TRIPPED", "E_STOPPED", "UNKNOWN"]
Quality = Literal["GOOD", "BAD", "UNCERTAIN", "STALE", "OUT_OF_RANGE"]
Severity = Literal["INFO", "WARNING", "HIGH"]
CommandStatus = Literal["ACCEPTED", "NOOP", "REJECTED", "FAILED"]


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def utc_iso(value: Optional[datetime] = None) -> str:
    value = value or utc_now()
    if value.tzinfo is None:
        value = value.replace(tzinfo=timezone.utc)
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def model_dump(value: Any) -> Any:
    """Serialize Pydantic v1/v2 models with public aliases."""

    if isinstance(value, BaseModel):
        if hasattr(value, "model_dump"):
            return value.model_dump(by_alias=True, mode="json")  # type: ignore[attr-defined]
        return json.loads(value.json(by_alias=True))
    if isinstance(value, dict):
        return {key: model_dump(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [model_dump(item) for item in value]
    if isinstance(value, datetime):
        return utc_iso(value)
    return value


class OracleModel(BaseModel):
    model_config = ConfigDict(
        populate_by_name=True,
        extra="forbid",
        validate_assignment=True,
    )


class UserSnapshot(OracleModel):
    id: str
    username: str
    display_name: str = Field(alias="displayName")
    role: Role


class LoginRequest(OracleModel):
    username: str
    password: str


class LoginResponse(OracleModel):
    user: UserSnapshot
    expires_at: datetime = Field(alias="expiresAt")


class MeResponse(LoginResponse):
    pass


class TrendPoint(OracleModel):
    time: int
    value: float


class TagSnapshot(OracleModel):
    id: Optional[str] = None
    equipment_id: Optional[str] = Field(default=None, alias="equipmentId")
    kind: Optional[str] = None
    value: Union[StrictBool, StrictFloat]
    unit: str
    min_value: Optional[float] = Field(default=None, alias="min")
    max_value: Optional[float] = Field(default=None, alias="max")
    quality: Quality
    label: str
    timestamp: Optional[datetime] = None
    read_only: Optional[bool] = Field(default=None, alias="readOnly")
    history: List[TrendPoint] = Field(default_factory=list)


class SystemSnapshot(OracleModel):
    name: str
    site: str
    process_line: str = Field(alias="processLine")
    mode: Mode
    state: ProcessState
    connected: bool
    plc: str
    scan_ms: int = Field(alias="scanMs")
    simulation: bool = True
    updated_at: datetime = Field(alias="updatedAt")
    state_version: Optional[int] = Field(default=None, alias="stateVersion")
    sequence: Optional[str] = None


class AlarmSnapshot(OracleModel):
    id: str
    source: str
    message: str
    severity: Severity
    active: bool
    acknowledged: bool
    since: datetime
    last_changed_at: datetime = Field(alias="lastChangedAt")
    acknowledged_at: Optional[datetime] = Field(default=None, alias="acknowledgedAt")
    acknowledged_by: Optional[str] = Field(default=None, alias="acknowledgedBy")
    cleared_at: Optional[datetime] = Field(default=None, alias="clearedAt")
    activation_count: Optional[int] = Field(default=None, alias="activationCount")


class AuditEvent(OracleModel):
    id: str
    time: datetime
    source: str
    message: str
    severity: Severity
    actor: Optional[str] = None
    role: Optional[Role] = None
    action: Optional[str] = None
    equipment_id: Optional[str] = Field(default=None, alias="equipmentId")
    result: Optional[str] = None
    reason_code: Optional[str] = Field(default=None, alias="reasonCode")
    command_id: Optional[str] = Field(default=None, alias="commandId")
    state_version: Optional[int] = Field(default=None, alias="stateVersion")
    related_alarm_id: Optional[str] = Field(default=None, alias="relatedAlarmId")


class StateSnapshot(OracleModel):
    schema_version: int = Field(default=1, alias="schemaVersion")
    state_version: int = Field(alias="stateVersion")
    emitted_at: datetime = Field(alias="emittedAt")
    system: SystemSnapshot
    tags: Dict[str, TagSnapshot]
    alarms: List[AlarmSnapshot]
    events: List[AuditEvent]
    equipment: Optional[Any] = None
    capabilities: Optional[List[Dict[str, Any]]] = None
    permissives: Optional[List[Dict[str, Any]]] = None
    interlocks: Optional[List[Dict[str, Any]]] = None
    alarm_history: Optional[List[Dict[str, Any]]] = Field(default=None, alias="alarmHistory")
    faults: Optional[List[str]] = None


CommandAction = Literal[
    "start", "stop", "open-inlet", "close-inlet", "open-outlet", "close-outlet", "set-mode", "ack-all", "reset-simulator", "set-sim-config"
]


class CommandRequest(OracleModel):
    # Empty is allowed so the richer equipment payload can use ``command``
    # while the runtime normalizes both forms at the logic boundary.
    action: str = ""
    # Richer logic-command compatibility fields are accepted but not required
    # by the primary HMI contract.
    command: Optional[str] = None
    mode: Optional[Mode] = None
    alarm_id: Optional[str] = Field(default=None, alias="alarmId")
    client_command_id: Optional[str] = Field(default=None, alias="clientCommandId")
    request_id: Optional[str] = Field(default=None, alias="requestId")
    equipment_id: Optional[str] = Field(default=None, alias="equipmentId")
    expected_state_version: Optional[int] = Field(default=None, alias="expectedStateVersion")
    reason: Optional[str] = None
    parameters: Dict[str, Any] = Field(default_factory=dict)
    noise_scale: Optional[float] = Field(default=None, alias="noiseScale", ge=0.0, le=2.0)


class CommandResult(OracleModel):
    accepted: bool
    status: CommandStatus
    action: str = ""
    command_id: str = Field(alias="commandId")
    request_id: Optional[str] = Field(default=None, alias="requestId")
    state_version: int = Field(alias="stateVersion")
    reason: Optional[str] = None
    reason_code: Optional[str] = Field(default=None, alias="reasonCode")
    message: str
    resulting_state: Optional[str] = Field(default=None, alias="resultingState")


class HealthResponse(OracleModel):
    ok: bool
    service: str
    simulator: str
    connected: bool
    plc: str
    simulation: bool = True
    state_version: int = Field(alias="stateVersion")
    scan_age_ms: int = Field(alias="scanAgeMs")
    subscriber_count: Optional[int] = Field(default=None, alias="subscriberCount")


class ErrorEnvelope(OracleModel):
    error: str
    code: str
    message: str
    details: Optional[Any] = None
    accepted: Optional[bool] = None
    action: Optional[str] = None
    command_id: Optional[str] = Field(default=None, alias="commandId")
    state_version: Optional[int] = Field(default=None, alias="stateVersion")


class OracleAPIError(Exception):
    """Expected API failure rendered as an Oracle error envelope."""

    def __init__(self, status_code: int, code: str, message: str, *, error: str = "Request failed", details: Any = None) -> None:
        super().__init__(message)
        self.status_code = status_code
        self.code = code
        self.message = message
        self.error = error
        self.details = details
