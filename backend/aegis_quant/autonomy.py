"""Current-session health for the Windows Store read-only engine."""

from __future__ import annotations

import json
import os
import threading
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .paths import STORAGE_ROOT
from .runtime_policy import STORE_EDITION


STATE_PATH = STORAGE_ROOT / "runtime" / "engine_state.json"


def _utc_now() -> datetime:
    return datetime.now(timezone.utc)


def _iso_now() -> str:
    return _utc_now().isoformat()


class AutonomyMonitor:
    """Record health only; no scheduler, trading cadence or restart supervisor."""

    def __init__(self, state_path: Path = STATE_PATH) -> None:
        self.state_path = state_path
        self._lock = threading.Lock()
        previous = self._read()
        now = _iso_now()
        self._state: dict[str, Any] = {
            "edition": STORE_EDITION,
            "processStartedAt": now,
            "lastHeartbeatAt": now,
            "launchCount": int(previous.get("launchCount") or 0) + 1,
            "processId": os.getpid(),
            "schedulerRegistered": False,
            "executionRegistered": False,
        }
        self._write()

    def _read(self) -> dict[str, Any]:
        try:
            loaded = json.loads(self.state_path.read_text(encoding="utf-8"))
            return loaded if isinstance(loaded, dict) else {}
        except (FileNotFoundError, json.JSONDecodeError, OSError):
            return {}

    def _write(self) -> None:
        self.state_path.parent.mkdir(parents=True, exist_ok=True)
        temporary = self.state_path.with_suffix(".tmp")
        temporary.write_text(
            json.dumps(self._state, ensure_ascii=False, indent=2), encoding="utf-8"
        )
        temporary.replace(self.state_path)

    def record_heartbeat(self) -> None:
        with self._lock:
            self._state["lastHeartbeatAt"] = _iso_now()
            self._write()

    def snapshot(self) -> dict[str, Any]:
        with self._lock:
            state = dict(self._state)
        now = _utc_now()
        try:
            heartbeat = datetime.fromisoformat(str(state.get("lastHeartbeatAt")))
            heartbeat_age = max(0.0, (now - heartbeat).total_seconds())
        except (TypeError, ValueError):
            heartbeat_age = float("inf")
        try:
            started = datetime.fromisoformat(str(state.get("processStartedAt")))
            uptime = max(0, int((now - started).total_seconds()))
        except (TypeError, ValueError):
            uptime = 0
        healthy = heartbeat_age <= 90
        return {
            **state,
            "engineState": "ACTIVE" if healthy else "DEGRADED",
            "healthy": healthy,
            "heartbeatAgeSeconds": round(heartbeat_age, 1),
            "uptimeSeconds": uptime,
            "schedulerIntervalSeconds": 0,
            "nextDailyRefreshLocal": None,
            "independence": {
                "requiresCodex": False,
                "requiresBrowser": False,
                "requiresWindowsAwake": True,
                "requiresUserLoggedIn": True,
                "serverSelfHealing": False,
                "cloudAlwaysOn": False,
            },
            "boundaryMessage": (
                "Windows Store 只读版仅在应用打开时运行；"
                "不注册订单、自动交易或后台调度器"
            ),
        }
