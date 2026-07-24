from __future__ import annotations

import json
import os
import threading
from datetime import datetime, time, timedelta, timezone
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo

from .paths import STORAGE_ROOT


STATE_PATH = STORAGE_ROOT / "runtime" / "autonomy_state.json"
RANKINGS_PATH = STORAGE_ROOT / "models" / "nasdaq100" / "latest_rankings.csv"
LOCAL_TIME = ZoneInfo("Asia/Kuala_Lumpur")


DECISION_TEXT = {
    "STARTING": "后台引擎启动",
    "DISABLED": "自动做T已暂停",
    "SCHEDULER_BUSY": "上一轮决策尚未结束",
    "ORDER_PENDING": "存在未完成的模拟委托",
    "GOAL_COMPLETE": "当日训练成交目标已完成",
    "WAITING_FIRST_SLOT": "等待首个交易时间窗",
    "WAITING_NEXT_SLOT": "等待下一个交易时间窗",
    "RETRY_COOLDOWN": "委托冷却期内",
    "MAX_ATTEMPTS": "当日尝试次数已达上限",
    "NO_STOCK_IN_T_BUY_ZONE": "尚无候选股进入ATR做T买入区",
    "WAIT_T_SELL_ZONE": "持仓正在等待ATR卖出区或止损",
    "NO_QUOTE_CANDIDATE": "候选股实时行情不可用",
    "FULL_EXPOSURE_ENTRY": "正在建立前五名100%目标核心仓",
    "CORE_ORDERS_PENDING": "核心满仓委托正在成交",
    "CORE_FUNDS_UNAVAILABLE": "核心仓资金数据不可用",
    "NO_CORE_CANDIDATES": "暂无可建立核心仓的进攻候选",
    "CORE_MARKET_NOT_OPEN": "核心仓等待美股常规时段",
    "CORE_ENTRY_REJECTED": "核心仓委托被模拟盘拒绝",
    "FULL_EXPOSURE_TOP_UP": "核心仓正在自动补至接近100%",
    "CORE_TOP_UP_UNAVAILABLE": "核心仓等待可用资金或行情补仓",
}


def _utc_now() -> datetime:
    return datetime.now(timezone.utc)


def _iso_now() -> str:
    return _utc_now().isoformat()


def _next_weekday_refresh(now: datetime) -> datetime:
    local_now = now.astimezone(LOCAL_TIME)
    candidate = datetime.combine(local_now.date(), time(5, 30), tzinfo=LOCAL_TIME)
    if candidate <= local_now:
        candidate += timedelta(days=1)
    while candidate.weekday() >= 5:
        candidate += timedelta(days=1)
    return candidate


class AutonomyMonitor:
    """Persistent proof that the local engine is ticking without a browser or Codex."""

    def __init__(self, state_path: Path = STATE_PATH) -> None:
        self.state_path = state_path
        self._lock = threading.Lock()
        previous = self._read()
        self._state: dict[str, Any] = {
            **previous,
            "processStartedAt": _iso_now(),
            "lastHeartbeatAt": _iso_now(),
            "schedulerTicksProcess": 0,
            "schedulerTicksLifetime": int(previous.get("schedulerTicksLifetime") or 0),
            "restartCount": int(previous.get("restartCount") or 0) + 1,
            "lastDecision": "STARTUP",
            "lastDecisionText": DECISION_TEXT["STARTING"],
            "lastDecisionAt": _iso_now(),
            "consecutiveErrors": 0,
            "processId": os.getpid(),
        }
        self._write()

    def _read(self) -> dict[str, Any]:
        try:
            return json.loads(self.state_path.read_text(encoding="utf-8"))
        except (FileNotFoundError, json.JSONDecodeError, OSError):
            return {}

    def _write(self) -> None:
        self.state_path.parent.mkdir(parents=True, exist_ok=True)
        temporary = self.state_path.with_suffix(".tmp")
        temporary.write_text(
            json.dumps(self._state, ensure_ascii=False, indent=2), encoding="utf-8"
        )
        temporary.replace(self.state_path)

    def record_tick(self, result: dict[str, Any]) -> None:
        with self._lock:
            now = _iso_now()
            action = str(result.get("action") or "SKIP")
            reason = str(result.get("reason") or action)
            decision = action if action != "SKIP" else reason
            self._state.update(
                {
                    "lastHeartbeatAt": now,
                    "lastDecisionAt": now,
                    "lastDecision": decision,
                    "lastDecisionText": DECISION_TEXT.get(
                        decision, str(result.get("rationale") or decision)
                    ),
                    "lastDecisionPayload": result,
                    "schedulerTicksProcess": int(self._state.get("schedulerTicksProcess") or 0) + 1,
                    "schedulerTicksLifetime": int(self._state.get("schedulerTicksLifetime") or 0) + 1,
                    "consecutiveErrors": 0,
                    "lastSuccessfulTickAt": now,
                }
            )
            self._write()

    def record_heartbeat(self) -> None:
        """Prove the supervisor is alive independently of broker request latency."""
        with self._lock:
            self._state["lastHeartbeatAt"] = _iso_now()
            self._write()

    def record_error(self, error: Exception) -> None:
        with self._lock:
            now = _iso_now()
            self._state.update(
                {
                    "lastHeartbeatAt": now,
                    "lastDecisionAt": now,
                    "lastDecision": "ERROR",
                    "lastDecisionText": "调度器异常，守护程序将继续重试",
                    "lastError": str(error),
                    "lastErrorAt": now,
                    "schedulerTicksProcess": int(self._state.get("schedulerTicksProcess") or 0) + 1,
                    "schedulerTicksLifetime": int(self._state.get("schedulerTicksLifetime") or 0) + 1,
                    "consecutiveErrors": int(self._state.get("consecutiveErrors") or 0) + 1,
                }
            )
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
        try:
            decision_at = datetime.fromisoformat(str(state.get("lastDecisionAt")))
            decision_age = max(0.0, (now - decision_at).total_seconds())
        except (TypeError, ValueError):
            decision_age = float("inf")
        ranking_updated_at = None
        if RANKINGS_PATH.exists():
            ranking_updated_at = datetime.fromtimestamp(
                RANKINGS_PATH.stat().st_mtime, tz=timezone.utc
            ).isoformat()
        healthy = (
            heartbeat_age <= 90
            and decision_age <= 180
            and int(state.get("consecutiveErrors") or 0) < 3
        )
        return {
            **state,
            "engineState": "ACTIVE" if healthy else "DEGRADED",
            "healthy": healthy,
            "heartbeatAgeSeconds": round(heartbeat_age, 1),
            "decisionAgeSeconds": round(decision_age, 1),
            "uptimeSeconds": uptime,
            "schedulerIntervalSeconds": 30,
            "rankingUpdatedAt": ranking_updated_at,
            "nextDailyRefreshLocal": _next_weekday_refresh(now).isoformat(),
            "independence": {
                "requiresCodex": False,
                "requiresBrowser": False,
                "requiresMacAwake": True,
                "requiresUserLoggedIn": True,
                "requiresOpenD": True,
                "serverSelfHealing": True,
                "openDSelfHealing": True,
                "cloudAlwaysOn": False,
            },
            "boundaryMessage": "无需Codex或浏览器；Mac必须开机、用户已登录且OpenD保持模拟账户授权",
        }
