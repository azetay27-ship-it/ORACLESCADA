"""Runtime tag registry and bounded trend histories."""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Any, Mapping

from .catalog import TAG_ALIASES, TAG_CATALOG
from .models import Quality, TagDefinition, TagValue


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


class TagRegistry:
    """Owns tag definitions, values, quality, and the 90-point trend window."""

    def __init__(self, *, history_size: int = 90, now: datetime | None = None) -> None:
        self.history_size = max(1, int(history_size))
        timestamp = now or utc_now()
        self._values: dict[str, TagValue] = {}
        for definition in TAG_CATALOG:
            initial = self._default_value(definition)
            self._values[definition.id] = TagValue(definition, initial, Quality.GOOD, timestamp, [])

    @staticmethod
    def _default_value(definition: TagDefinition) -> Any:
        if definition.value_type == "bool":
            return False
        if definition.id in {"TK-101.level", "LIT-101.level"}:
            return 62.4
        if definition.id in {"TK-102.level", "LIT-102.level"}:
            return 41.8
        if definition.id == "FT-101.flow":
            return 0.0
        if definition.id == "PT-101.pressure":
            return 0.0
        if definition.id == "AIT-101.ph":
            return 7.1
        if definition.id == "TT-101.temperature":
            return 26.4
        return 0.0

    def definitions(self) -> list[dict[str, Any]]:
        return [definition.as_dict() for definition in TAG_CATALOG]

    def _canonical(self, tag_id: str) -> str:
        return TAG_ALIASES.get(tag_id, tag_id)

    def has(self, tag_id: str) -> bool:
        return tag_id in self._values

    def definition(self, tag_id: str) -> TagDefinition:
        return self._values[tag_id].definition

    def get(self, tag_id: str) -> Any:
        return self._values[self._canonical(tag_id)].value

    def quality(self, tag_id: str) -> Quality:
        return self._values[self._canonical(tag_id)].quality

    def timestamp(self, tag_id: str) -> datetime:
        return self._values[self._canonical(tag_id)].timestamp

    def set(
        self,
        tag_id: str,
        value: Any,
        *,
        timestamp: datetime | None = None,
        quality: Quality = Quality.GOOD,
        record_history: bool = True,
    ) -> None:
        canonical = self._canonical(tag_id)
        if canonical not in self._values:
            raise KeyError(f"Unknown tag: {tag_id}")
        item = self._values[canonical]
        value = self._coerce_value(item.definition, value)
        stamp = timestamp or item.timestamp or utc_now()
        item.value = value
        item.quality = quality
        item.timestamp = stamp
        if record_history and isinstance(value, (int, float)) and not isinstance(value, bool):
            item.history.append({"time": int(stamp.timestamp() * 1000), "value": float(value)})
            del item.history[:-self.history_size]

    def set_quality(self, tag_id: str, quality: Quality, *, timestamp: datetime | None = None) -> None:
        canonical = self._canonical(tag_id)
        if canonical not in self._values:
            raise KeyError(f"Unknown tag: {tag_id}")
        item = self._values[canonical]
        item.quality = quality
        if timestamp is not None:
            item.timestamp = timestamp

    def update_many(
        self,
        values: Mapping[str, Any],
        *,
        timestamp: datetime | None = None,
        quality: Quality = Quality.GOOD,
    ) -> None:
        for tag_id, value in values.items():
            self.set(tag_id, value, timestamp=timestamp, quality=quality)

    def snapshot(self) -> dict[str, dict[str, Any]]:
        """Return a detached, JSON-ready snapshot including aliases."""

        result: dict[str, dict[str, Any]] = {}
        for tag_id, item in self._values.items():
            result[tag_id] = item.as_dict()
        for alias, canonical in TAG_ALIASES.items():
            source = result[canonical].copy()
            source["id"] = alias
            source["equipmentId"] = alias.split(".", 1)[0]
            source["label"] = self._values[alias].definition.description
            result[alias] = source
        return result

    def reset(self, *, now: datetime | None = None) -> None:
        timestamp = now or utc_now()
        for definition in TAG_CATALOG:
            item = self._values[definition.id]
            item.value = self._default_value(definition)
            item.quality = Quality.GOOD
            item.timestamp = timestamp
            item.history.clear()

    @staticmethod
    def _coerce_value(definition: TagDefinition, value: Any) -> Any:
        if definition.value_type == "bool":
            if not isinstance(value, bool):
                raise TypeError(f"{definition.id} requires a boolean value")
            return value
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            raise TypeError(f"{definition.id} requires a numeric value")
        result = float(value)
        if definition.minimum is not None:
            result = max(definition.minimum, result)
        if definition.maximum is not None:
            result = min(definition.maximum, result)
        return result

