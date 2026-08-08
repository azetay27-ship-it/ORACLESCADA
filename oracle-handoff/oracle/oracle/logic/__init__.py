"""Oracle NILIT Line 1 industrial control-logic package.

Only the simulator adapter is shipped in v1.  No class in this package opens a
socket, talks to a PLC, writes to a file, or performs physical I/O.
"""

from .catalog import EQUIPMENT_CATALOG, TAG_ALIASES, TAG_CATALOG, equipment_catalog, tag_catalog
from .engine import ControlLogic, Line1Logic, OracleLine1Logic
from .models import (
    AlarmRecord,
    AuditEvent,
    CommandResult,
    CommandStatus,
    EquipmentMetadata,
    EquipmentStatus,
    Interlock,
    LineState,
    Mode,
    Permissive,
    PumpState,
    Quality,
    Severity,
    TagDefinition,
    TagValue,
    ValveState,
)
from .tags import TagRegistry

__all__ = [
    "AlarmRecord",
    "AuditEvent",
    "CommandResult",
    "CommandStatus",
    "ControlLogic",
    "EQUIPMENT_CATALOG",
    "EquipmentMetadata",
    "EquipmentStatus",
    "Interlock",
    "Line1Logic",
    "LineState",
    "Mode",
    "OracleLine1Logic",
    "Permissive",
    "PumpState",
    "Quality",
    "Severity",
    "TAG_ALIASES",
    "TAG_CATALOG",
    "TagDefinition",
    "TagRegistry",
    "TagValue",
    "ValveState",
    "equipment_catalog",
    "tag_catalog",
]

