"""Draft and published screen documents for the Oracle SVG editor.

Screen documents are deliberately separate from the plant-control domain. They
contain geometry, bindings, and declared capabilities only; command execution
continues to belong to the authenticated control API.
"""

from __future__ import annotations

import copy
import json
import os
import re
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from threading import RLock
from typing import Any, Mapping

from .logic import tag_catalog


SCREEN_ID = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9_-]{0,79}$")
PART_TYPES = {
    "tank", "vessel", "pump", "fan", "compressor", "filter", "heat-exchanger",
    "manual-valve", "actuated-valve", "check-valve", "control-valve", "instrument",
    "gauge", "level-bar", "status-lamp", "alarm-badge", "mini-trend", "pipe",
    "elbow", "reducer", "text", "rectangle", "ellipse", "nav-button", "command-button",
    "mode-indicator", "alarm-summary", "timestamp", "site-header",
}


class ScreenStoreError(Exception):
    pass


class ScreenNotFound(ScreenStoreError):
    pass


class ScreenConflict(ScreenStoreError):
    pass


def _now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def default_screen() -> dict[str, Any]:
    return {
        "schemaVersion": 1,
        "id": "screen-line-1-overview",
        "name": "NILIT Line 1 Overview",
        "status": "published",
        "revision": 1,
        "viewport": {"width": 1920, "height": 1080, "background": "#07101a"},
        "grid": {"size": 8, "visible": True, "snap": True},
        "layers": [{"id": "layer-process", "name": "Process", "zIndex": 10, "visible": True, "locked": False}],
        "elements": [
            {"id": "element-tk-101", "type": "tank", "layerId": "layer-process", "frame": {"x": 240, "y": 280, "width": 180, "height": 260, "rotation": 0}, "props": {"label": "TK-101"}, "bindings": {"level": {"tagKey": "TK-101.level"}}},
            {"id": "element-p-101", "type": "pump", "layerId": "layer-process", "frame": {"x": 720, "y": 390, "width": 120, "height": 120, "rotation": 0}, "props": {"label": "P-101"}, "bindings": {"state": {"tagKey": "P-101.run"}}},
            {"id": "element-tk-102", "type": "tank", "layerId": "layer-process", "frame": {"x": 1240, "y": 280, "width": 180, "height": 260, "rotation": 0}, "props": {"label": "TK-102"}, "bindings": {"level": {"tagKey": "TK-102.level"}}},
        ],
        "connectors": [
            {"id": "connector-101", "type": "pipe", "source": {"elementId": "element-tk-101", "portId": "outlet"}, "target": {"elementId": "element-p-101", "portId": "inlet"}, "waypoints": [], "style": {"routing": "orthogonal"}, "bindings": {"flowTagKey": "FT-101.flow"}},
            {"id": "connector-102", "type": "pipe", "source": {"elementId": "element-p-101", "portId": "outlet"}, "target": {"elementId": "element-tk-102", "portId": "inlet"}, "waypoints": [], "style": {"routing": "orthogonal"}, "bindings": {"flowTagKey": "FT-101.flow"}},
        ],
        "metadata": {"createdAt": _now(), "updatedAt": _now(), "createdBy": "system", "updatedBy": "system"},
    }


class ScreenStore:
    def __init__(self, root: Path) -> None:
        self.root = Path(root)
        self._lock = RLock()
        self._memory: dict[str, dict[str, Any]] = {}

    def _valid_id(self, screen_id: str) -> str:
        if not SCREEN_ID.fullmatch(screen_id):
            raise ScreenStoreError("Screen ID must contain only letters, numbers, hyphens, and underscores.")
        return screen_id

    def _path(self, screen_id: str) -> Path:
        return self.root / f"{self._valid_id(screen_id)}.json"

    def _load(self, screen_id: str) -> dict[str, Any] | None:
        if screen_id in self._memory:
            return copy.deepcopy(self._memory[screen_id])
        path = self._path(screen_id)
        if not path.is_file():
            return None
        try:
            return json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            raise ScreenStoreError(f"Screen document could not be read: {exc}") from exc

    def _write(self, document: Mapping[str, Any]) -> dict[str, Any]:
        payload = copy.deepcopy(dict(document))
        self._memory[str(payload["id"])] = payload
        try:
            self.root.mkdir(parents=True, exist_ok=True)
            with tempfile.NamedTemporaryFile("w", encoding="utf-8", suffix=".tmp", dir=self.root, delete=False) as handle:
                json.dump(payload, handle, ensure_ascii=False, indent=2)
                handle.write("\n")
                temp_name = handle.name
            os.replace(temp_name, self._path(str(payload["id"])))
        except OSError:
            # The container defaults to an in-memory editor when its filesystem
            # is read-only; the API contract remains identical.
            try:
                if "temp_name" in locals() and Path(temp_name).exists():
                    Path(temp_name).unlink()
            except OSError:
                pass
        return copy.deepcopy(payload)

    def get(self, screen_id: str) -> dict[str, Any]:
        with self._lock:
            document = self._load(screen_id)
            if document is None and screen_id == "screen-line-1-overview":
                document = default_screen()
            if document is None:
                raise ScreenNotFound(screen_id)
            return copy.deepcopy(document)

    def list(self) -> list[dict[str, Any]]:
        with self._lock:
            documents: dict[str, dict[str, Any]] = {"screen-line-1-overview": default_screen()}
            for path in self.root.glob("*.json") if self.root.is_dir() else []:
                loaded = self._load(path.stem)
                if loaded:
                    documents[path.stem] = loaded
            documents.update(copy.deepcopy(self._memory))
            return [{"id": doc["id"], "name": doc.get("name", doc["id"]), "status": doc.get("status", "draft"), "revision": doc.get("revision", 1), "updatedAt": doc.get("metadata", {}).get("updatedAt")} for doc in documents.values()]

    def save(self, document: Mapping[str, Any], *, user: str, expected_revision: int | None = None) -> dict[str, Any]:
        with self._lock:
            candidate = copy.deepcopy(dict(document))
            screen_id = self._valid_id(str(candidate.get("id", "")))
            existing = self._load(screen_id)
            if existing is None and screen_id == "screen-line-1-overview":
                existing = default_screen()
            if existing is not None and expected_revision is not None and int(existing.get("revision", 1)) != expected_revision:
                raise ScreenConflict(f"Screen revision conflict; server is at revision {existing.get('revision', 1)}.")
            candidate["id"] = screen_id
            candidate["revision"] = int(existing.get("revision", 0)) + 1 if existing else int(candidate.get("revision", 0) or 0) + 1
            candidate["status"] = "draft"
            metadata = dict(candidate.get("metadata") or {})
            metadata.setdefault("createdAt", existing.get("metadata", {}).get("createdAt", _now()) if existing else _now())
            metadata.setdefault("createdBy", existing.get("metadata", {}).get("createdBy", user) if existing else user)
            metadata["updatedAt"] = _now()
            metadata["updatedBy"] = user
            candidate["metadata"] = metadata
            return self._write(candidate)

    def create(self, document: Mapping[str, Any], *, user: str) -> dict[str, Any]:
        screen_id = str(document.get("id", ""))
        if screen_id and self._load(screen_id) is not None:
            raise ScreenConflict(f"Screen {screen_id} already exists.")
        if not screen_id:
            document = {**document, "id": f"screen-{len(self.list()) + 1}"}
        return self.save(document, user=user, expected_revision=None)

    def duplicate(self, screen_id: str, *, user: str, new_id: str | None = None) -> dict[str, Any]:
        source = self.get(screen_id)
        target_id = new_id or f"{screen_id}-copy"
        self._valid_id(target_id)
        if self._load(target_id) is not None:
            raise ScreenConflict(f"Screen {target_id} already exists.")
        source["id"] = target_id
        source["name"] = f"{source.get('name', screen_id)} Copy"
        source["revision"] = 0
        source["status"] = "draft"
        return self.save(source, user=user)

    def validate(self, document: Mapping[str, Any]) -> dict[str, Any]:
        errors: list[str] = []
        warnings: list[str] = []
        screen_id = str(document.get("id", ""))
        if not screen_id or not SCREEN_ID.fullmatch(screen_id): errors.append("Screen ID is missing or invalid.")
        if not str(document.get("name", "")).strip(): errors.append("Screen name is required.")
        elements = document.get("elements", [])
        if not isinstance(elements, list): elements = []
        ids = [str(item.get("id", "")) for item in elements if isinstance(item, Mapping)]
        if len(ids) != len(set(ids)): errors.append("Element IDs must be unique.")
        by_id = set(ids)
        for element in elements:
            if not isinstance(element, Mapping): errors.append("Every element must be an object."); continue
            if element.get("type") not in PART_TYPES: errors.append(f"Unknown element type: {element.get('type')}.")
            frame = element.get("frame", {})
            if not isinstance(frame, Mapping) or float(frame.get("width", 0)) <= 0 or float(frame.get("height", 0)) <= 0: errors.append(f"Element {element.get('id', '')} has invalid geometry.")
            for binding in (element.get("bindings", {}) or {}).values():
                if isinstance(binding, Mapping) and binding.get("tagKey") and not any(item.get("id") == binding.get("tagKey") for item in tag_catalog()): warnings.append(f"Binding references unknown tag {binding.get('tagKey')}.")
        for connector in document.get("connectors", []) if isinstance(document.get("connectors", []), list) else []:
            for endpoint in (connector.get("source", {}), connector.get("target", {})):
                if endpoint.get("elementId") not in by_id: errors.append(f"Connector {connector.get('id', '')} references a missing element.")
        if not elements: warnings.append("Screen has no process elements.")
        return {"valid": not errors, "errors": errors, "warnings": warnings}

    def publish(self, screen_id: str, *, user: str, expected_revision: int | None = None) -> dict[str, Any]:
        document = self.get(screen_id)
        result = self.validate(document)
        if not result["valid"]: raise ScreenStoreError("Screen cannot be published until validation errors are fixed.")
        document["status"] = "published"
        saved = self.save(document, user=user, expected_revision=expected_revision or int(document.get("revision", 1)))
        saved["status"] = "published"
        return self._write(saved)

    @staticmethod
    def parts() -> list[dict[str, Any]]:
        return [{"type": item, "label": item.replace("-", " ").title()} for item in sorted(PART_TYPES)]

    @staticmethod
    def templates() -> list[dict[str, Any]]:
        return [{"id": "line-1-overview", "name": "NILIT Line 1 Overview", "screenId": "screen-line-1-overview"}, {"id": "blank-1920", "name": "Blank 1920 × 1080", "screenId": None}]

    @staticmethod
    def tag_catalog() -> list[dict[str, Any]]:
        return tag_catalog()

    @staticmethod
    def capabilities() -> list[dict[str, Any]]:
        return [{"id": "line.start", "action": "start", "label": "Start transfer"}, {"id": "line.stop", "action": "stop", "label": "Stop transfer"}, {"id": "valve.xv101.open", "action": "open-inlet", "label": "Open inlet"}, {"id": "valve.xv101.close", "action": "close-inlet", "label": "Close inlet"}, {"id": "alarm.ack-all", "action": "ack-all", "label": "Acknowledge all alarms"}]
