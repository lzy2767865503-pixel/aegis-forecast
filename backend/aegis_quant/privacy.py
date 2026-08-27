"""Local privacy preferences for the Store research workstation."""

from __future__ import annotations

import json
import threading
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .paths import STORAGE_ROOT, ensure_directories


PRIVACY_SETTINGS_PATH = STORAGE_ROOT / "settings" / "privacy.json"


class PrivacyPreferences:
    def __init__(self, path: Path = PRIVACY_SETTINGS_PATH) -> None:
        self.path = path
        self._lock = threading.Lock()

    @staticmethod
    def _defaults() -> dict[str, Any]:
        return {
            "researchNoticeAccepted": False,
            "policyVersion": "2026-08-27",
            "updatedAt": None,
        }

    def status(self) -> dict[str, Any]:
        with self._lock:
            values = self._defaults()
            try:
                loaded = json.loads(self.path.read_text(encoding="utf-8"))
                if isinstance(loaded, dict):
                    values.update(
                        {
                            key: loaded[key]
                            for key in values
                            if key in loaded
                        }
                    )
            except (FileNotFoundError, json.JSONDecodeError, OSError):
                pass
            return values

    def update(self, payload: dict[str, Any]) -> dict[str, Any]:
        allowed = {"researchNoticeAccepted"}
        unknown = set(payload) - allowed
        if unknown:
            raise ValueError(f"Unsupported privacy setting: {sorted(unknown)[0]}")
        with self._lock:
            values = self.status_unlocked()
            for key in allowed:
                if key in payload:
                    if not isinstance(payload[key], bool):
                        raise ValueError(f"{key} must be a boolean")
                    values[key] = payload[key]
            values["updatedAt"] = datetime.now(timezone.utc).isoformat()
            ensure_directories()
            self.path.parent.mkdir(parents=True, exist_ok=True)
            temporary = self.path.with_suffix(".tmp")
            temporary.write_text(
                json.dumps(values, ensure_ascii=False, indent=2), encoding="utf-8"
            )
            temporary.replace(self.path)
            return dict(values)

    def status_unlocked(self) -> dict[str, Any]:
        values = self._defaults()
        try:
            loaded = json.loads(self.path.read_text(encoding="utf-8"))
            if isinstance(loaded, dict):
                values.update({key: loaded[key] for key in values if key in loaded})
        except (FileNotFoundError, json.JSONDecodeError, OSError):
            pass
        return values
