"""Public data models for the Oracle NILIT Line 1 control domain.

The logic package deliberately uses standard-library dataclasses and enums so it
can be embedded by FastAPI, a test harness, or a future PLC adapter without
creating a web-framework dependency in the control domain.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass, field
from datetime import datetime
from enum import Enum
from typing import Any, Optional


class StrEnum(str, Enum):
    """A JSON-friendly enum base for Python versions before enum.StrEnum."""

    def __str__(self) -> str:
        return self.value


class Mode(StrEnum):
    MANUAL = "MANUAL"
    AUTO = "AUTO"


class LineState(StrEnum):
    STOPPED = "STOPPED"
    STARTING = "STARTING"
    RUNNING = "RUNNING"
    STOPPING = "STOPPING"
    TRIPPED = "TRIPPED"
    E_STOPPED = "E_STOPPED"
    FAULT = "FAULT"


class ValveState(StrEnum):
    CLOSED = "CLOSED"
    OPENING = "OPENING"
    OPEN = "OPEN"
    CLOSING = "CLOSING"
    FAULT = "FAULT"
    UNKNOWN = "UNKNOWN"


class PumpState(StrEnum):
    STOPPED = "STOPPED"
    STARTING = "STARTING"
    RUNNING = "RUNNING"
    STOPPING = "STOPPING"
    TRIPPED = "TRIPPED"
    FAULT = "FAULT"
    UNKNOWN = "UNKNOWN"


class Quality(StrEnum):
    GOOD = "GOOD"
    UNCERTAIN = "UNCERTAIN"
    BAD = "BAD"
    STALE = "STALE"
    OUT_OF_RANGE = "OUT_OF_RANGE"


class Severity(StrEnum):
    INFO = "INFO"
    WARNING = "WARNING"
    HIGH = "HIGH"


class CommandStatus(StrEnum):
    ACCEPTED = "ACCEPTED"
    NOOP = "NOOP"
    REJECTED = "REJECTED"
    FAILED = "FAILED"


@dataclass(frozen=True)
class TagDefinition:
    id: str
    equipment_id: str
    kind: str
    unit: str
    value_type: str
    minimum: Optional[float] = None
    maximum: Optional[float] = None
    read_only: bool = True
    description: str = ""
    external_address: Optional[str] = None

    def as_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "equipmentId": self.equipment_id,
            "kind": self.kind,
            "unit": self.unit,
            "valueType": self.value_type,
            "min": self.minimum,
            "max": self.maximum,
            "readOnly": self.read_only,
            "description": self.description,
            "externalAddress": self.external_address,
        }


@dataclass(frozen=True)
class EquipmentMetadata:
    id: str
    type: str
    name: str
    description: str
    tags: tuple[str, ...] = ()
    ports: tuple[str, ...] = ()
    capabilities: tuple[str, ...] = ()
    safety_role: str = ""

    def as_dict(self) -> dict[str, Any]:
        return {
            "equipmentId": self.id,
            "id": self.id,
            "type": self.type,
            "name": self.name,
            "description": self.description,
            "tags": list(self.tags),
            "ports": list(self.ports),
            "capabilities": list(self.capabilities),
            "safetyRole": self.safety_role,
        }


@dataclass
class TagValue:
    definition: TagDefinition
    value: Any
    quality: Quality
    timestamp: datetime
    history: list[dict[str, Any]] = field(default_factory=list)

    def as_dict(self) -> dict[str, Any]:
        result = {
            "id": self.definition.id,
            "equipmentId": self.definition.equipment_id,
            "kind": self.definition.kind,
            "value": self.value,
            "unit": self.definition.unit,
            "min": self.definition.minimum,
            "max": self.definition.maximum,
            "quality": self.quality.value,
            "timestamp": self.timestamp.isoformat(),
            "readOnly": self.definition.read_only,
            "label": self.definition.description or self.definition.id,
            "history": list(self.history),
        }
        return result


@dataclass
class Permissive:
    id: str
    ok: bool
    message: str
    severity: Severity = Severity.WARNING

    def as_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "ok": self.ok,
            "message": self.message,
            "severity": self.severity.value,
        }


@dataclass
class Interlock:
    id: str
    active: bool
    message: str
    severity: Severity = Severity.HIGH

    def as_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "active": self.active,
            "message": self.message,
            "severity": self.severity.value,
        }


@dataclass
class EquipmentStatus:
    equipment_id: str
    type: str
    state: str
    mode: Mode
    commanded_state: str
    feedback_state: str
    healthy: bool
    permissives: list[Permissive] = field(default_factory=list)
    interlocks: list[Interlock] = field(default_factory=list)
    active_fault: Optional[str] = None
    last_transition: Optional[str] = None
    state_version: int = 0

    def as_dict(self) -> dict[str, Any]:
        return {
            "equipmentId": self.equipment_id,
            "type": self.type,
            "state": self.state,
            "mode": self.mode.value,
            "commandedState": self.commanded_state,
            "feedbackState": self.feedback_state,
            "healthy": self.healthy,
            "permissives": [item.as_dict() for item in self.permissives],
            "interlocks": [item.as_dict() for item in self.interlocks],
            "activeFault": self.active_fault,
            "lastTransition": self.last_transition,
            "stateVersion": self.state_version,
        }


@dataclass
class AlarmRecord:
    id: str
    source: str
    message: str
    severity: Severity
    active: bool
    acknowledged: bool
    since: str
    last_changed_at: str
    acknowledged_at: Optional[str] = None
    acknowledged_by: Optional[str] = None
    cleared_at: Optional[str] = None
    activation_count: int = 1

    def as_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "source": self.source,
            "message": self.message,
            "severity": self.severity.value,
            "active": self.active,
            "acknowledged": self.acknowledged,
            "since": self.since,
            "lastChangedAt": self.last_changed_at,
            "acknowledgedAt": self.acknowledged_at,
            "acknowledgedBy": self.acknowledged_by,
            "clearedAt": self.cleared_at,
            "activationCount": self.activation_count,
        }


@dataclass
class AuditEvent:
    id: str
    time: str
    source: str
    message: str
    severity: Severity = Severity.INFO
    actor: Optional[str] = None
    role: Optional[str] = None
    action: Optional[str] = None
    equipment_id: Optional[str] = None
    result: Optional[str] = None
    reason_code: Optional[str] = None
    command_id: Optional[str] = None
    state_version: int = 0
    related_alarm_id: Optional[str] = None

    def as_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "time": self.time,
            "source": self.source,
            "message": self.message,
            "severity": self.severity.value,
            "actor": self.actor,
            "role": self.role,
            "action": self.action,
            "equipmentId": self.equipment_id,
            "result": self.result,
            "reasonCode": self.reason_code,
            "commandId": self.command_id,
            "stateVersion": self.state_version,
            "relatedAlarmId": self.related_alarm_id,
        }


@dataclass
class CommandResult:
    accepted: bool
    status: CommandStatus
    action: str
    command_id: str
    request_id: Optional[str]
    state_version: int
    reason: Optional[str] = None
    reason_code: Optional[str] = None
    message: str = ""
    resulting_state: Optional[str] = None

    def as_dict(self) -> dict[str, Any]:
        return {
            "accepted": self.accepted,
            "status": self.status.value,
            "action": self.action,
            "commandId": self.command_id,
            "requestId": self.request_id,
            "stateVersion": self.state_version,
            "reason": self.reason,
            "reasonCode": self.reason_code,
            "message": self.message,
            "resultingState": self.resulting_state,
        }


def serialize(value: Any) -> Any:
    """Recursively turn public model values into JSON-ready primitives."""

    if isinstance(value, Enum):
        return value.value
    if hasattr(value, "as_dict"):
        return value.as_dict()
    if isinstance(value, dict):
        return {key: serialize(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [serialize(item) for item in value]
    if isinstance(value, datetime):
        return value.isoformat()
    if hasattr(value, "__dataclass_fields__"):
        return serialize(asdict(value))
    return value

