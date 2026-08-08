"""NILIT Line 1 equipment and tag catalogs.

The catalogs are immutable metadata. Runtime values live in :mod:`tags` and
equipment state lives in :mod:`engine`, which makes the control domain easy to
extend with another line or a future PLC/OPC UA adapter.
"""

from __future__ import annotations

from .models import EquipmentMetadata, TagDefinition


EQUIPMENT_CATALOG: tuple[EquipmentMetadata, ...] = (
    EquipmentMetadata(
        "TK-101", "tank", "Feed Tank TK-101", "NILIT Line 1 feed tank",
        tags=("TK-101.level", "LIT-101.level"),
        ports=("inlet", "outlet"),
        capabilities=("VIEW_LEVEL",),
        safety_role="low-level pump permissive",
    ),
    EquipmentMetadata(
        "TK-102", "tank", "Receiving Tank TK-102", "NILIT Line 1 receiving tank",
        tags=("TK-102.level", "LIT-102.level"),
        ports=("inlet", "outlet"),
        capabilities=("VIEW_LEVEL",),
        safety_role="high-level pump interlock",
    ),
    EquipmentMetadata(
        "XV-101", "actuated-valve", "Inlet Valve XV-101", "Feed tank inlet valve",
        tags=("XV-101.open",),
        ports=("inlet", "outlet"),
        capabilities=("OPEN", "CLOSE", "RESET"),
        safety_role="must be open before transfer",
    ),
    EquipmentMetadata(
        "XV-102", "actuated-valve", "Outlet Valve XV-102", "Receiving tank outlet valve",
        tags=("XV-102.open",),
        ports=("inlet", "outlet"),
        capabilities=("OPEN", "CLOSE", "RESET"),
        safety_role="must be open before transfer",
    ),
    EquipmentMetadata(
        "P-101", "pump", "Transfer Pump P-101", "NILIT Line 1 transfer pump",
        tags=("P-101.run",),
        ports=("suction", "discharge"),
        capabilities=("START", "STOP", "RESET"),
        safety_role="hard-tripped on unsafe process conditions",
    ),
    EquipmentMetadata(
        "M-101", "motor", "Pump Motor M-101", "Starter and run feedback for P-101",
        tags=("M-101.run",),
        ports=(),
        capabilities=("START", "STOP", "RESET"),
        safety_role="pump motor feedback",
    ),
    EquipmentMetadata(
        "LIT-101", "level-transmitter", "Feed Level LIT-101", "Feed tank level transmitter",
        tags=("LIT-101.level",),
        ports=(),
        capabilities=("VIEW_VALUE",),
        safety_role="critical start permissive",
    ),
    EquipmentMetadata(
        "LIT-102", "level-transmitter", "Receiving Level LIT-102", "Receiving tank level transmitter",
        tags=("LIT-102.level",),
        ports=(),
        capabilities=("VIEW_VALUE",),
        safety_role="critical high-level interlock",
    ),
    EquipmentMetadata(
        "FT-101", "flow-transmitter", "Transfer Flow FT-101", "Transfer line flow transmitter",
        tags=("FT-101.flow",),
        ports=(),
        capabilities=("VIEW_VALUE",),
        safety_role="no-flow running interlock",
    ),
    EquipmentMetadata(
        "PT-101", "pressure-transmitter", "Discharge Pressure PT-101", "Transfer discharge pressure transmitter",
        tags=("PT-101.pressure",),
        ports=(),
        capabilities=("VIEW_VALUE",),
        safety_role="high-pressure interlock",
    ),
    EquipmentMetadata(
        "AIT-101", "analyzer", "Process pH AIT-101", "Inline process pH analyzer",
        tags=("AIT-101.ph",),
        ports=(),
        capabilities=("VIEW_VALUE",),
        safety_role="quality alarm",
    ),
    EquipmentMetadata(
        "TT-101", "temperature-transmitter", "Process Temperature TT-101", "Inline process temperature transmitter",
        tags=("TT-101.temperature",),
        ports=(),
        capabilities=("VIEW_VALUE",),
        safety_role="quality alarm",
    ),
    EquipmentMetadata(
        "ESD-001", "emergency-stop", "Emergency Stop ESD-001", "Line emergency-stop status",
        tags=("ESD-001.active",),
        ports=(),
        capabilities=("RESET",),
        safety_role="hard stop and restart inhibit",
    ),
    EquipmentMetadata(
        "PLC-01", "controller", "Simulated PLC PLC-01", "Simulation adapter health",
        tags=("PLC-01.healthy",),
        ports=(),
        capabilities=("VIEW_HEALTH", "RESET"),
        safety_role="control and feedback health",
    ),
)


TAG_CATALOG: tuple[TagDefinition, ...] = (
    TagDefinition("TK-101.level", "TK-101", "level", "%", "float", 0, 100, True, "Feed tank level"),
    TagDefinition("TK-102.level", "TK-102", "level", "%", "float", 0, 100, True, "Receiving tank level"),
    TagDefinition("LIT-101.level", "LIT-101", "level", "%", "float", 0, 100, True, "Feed level transmitter"),
    TagDefinition("LIT-102.level", "LIT-102", "level", "%", "float", 0, 100, True, "Receiving level transmitter"),
    TagDefinition("FT-101.flow", "FT-101", "flow", "m³/h", "float", 0, 200, True, "Transfer flow"),
    TagDefinition("PT-101.pressure", "PT-101", "pressure", "bar", "float", 0, 8, True, "Discharge pressure"),
    TagDefinition("AIT-101.ph", "AIT-101", "pH", "pH", "float", 0, 14, True, "Process pH"),
    TagDefinition("TT-101.temperature", "TT-101", "temperature", "°C", "float", 0, 80, True, "Process temperature"),
    TagDefinition("P-101.run", "P-101", "run-feedback", "", "bool", 0, 1, True, "Transfer pump running"),
    TagDefinition("M-101.run", "M-101", "run-feedback", "", "bool", 0, 1, True, "Pump motor running"),
    TagDefinition("XV-101.open", "XV-101", "open-feedback", "", "bool", 0, 1, True, "Inlet valve open"),
    TagDefinition("XV-102.open", "XV-102", "open-feedback", "", "bool", 0, 1, True, "Outlet valve open"),
    TagDefinition("ESD-001.active", "ESD-001", "status", "", "bool", 0, 1, True, "Emergency stop active"),
    TagDefinition("PLC-01.healthy", "PLC-01", "status", "", "bool", 0, 1, True, "Simulation controller healthy"),
)


TAG_ALIASES: dict[str, str] = {
    "LIT-101.level": "TK-101.level",
    "LIT-102.level": "TK-102.level",
}


def equipment_catalog() -> list[dict]:
    return [item.as_dict() for item in EQUIPMENT_CATALOG]


def tag_catalog() -> list[dict]:
    return [item.as_dict() for item in TAG_CATALOG]


def equipment_by_id(equipment_id: str) -> EquipmentMetadata | None:
    wanted = equipment_id.upper()
    return next((item for item in EQUIPMENT_CATALOG if item.id == wanted), None)


def tag_definition(tag_id: str) -> TagDefinition | None:
    wanted = tag_id
    return next((item for item in TAG_CATALOG if item.id == wanted), None)

