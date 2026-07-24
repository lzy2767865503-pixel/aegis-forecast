from __future__ import annotations

import json
import math
import threading
from datetime import datetime
from pathlib import Path
from typing import Any, Callable
from zoneinfo import ZoneInfo

from .audit import AuditLedger
from .moomoo_gateway import MoomooSimulationGateway
from .paths import CONFIG_ROOT, STORAGE_ROOT


EASTERN_TIME = ZoneInfo("America/New_York")
POLICY_CONFIG = CONFIG_ROOT / "t_trading.json"
POLICY_STATE = STORAGE_ROOT / "paper" / "t_trading_policy.json"
OPEN_MARKET_STATES = {"MORNING", "AFTERNOON"}


class SimulationTTrader:
    """Paper-only cadence scheduler. It cannot address a REAL account."""

    def __init__(
        self,
        gateway: MoomooSimulationGateway,
        candidate_provider: Callable[[], list[dict[str, Any]]],
        audit: AuditLedger,
    ) -> None:
        self.gateway = gateway
        self.candidate_provider = candidate_provider
        self.audit = audit
        self._lock = threading.Lock()

    @staticmethod
    def _read_json(path: Path) -> dict[str, Any]:
        if not path.exists():
            return {}
        with path.open("r", encoding="utf-8") as handle:
            return json.load(handle)

    def policy(self) -> dict[str, Any]:
        policy = {
            "enabled": True,
            "targetExposurePct": 100.0,
            "minimumExposurePct": 99.9,
            "coreNames": 5,
            "executionBufferPct": 0.05,
            "neverIntentionallyFlat": True,
            "targetFilledOrdersPerDay": 5,
            "quantityPerOrder": 1,
            "scheduleEt": ["09:45", "10:45", "12:00", "13:30", "15:15"],
            "flattenEt": "15:50",
            "maxAttemptsPerDay": 10,
            "minimumRetryMinutes": 5,
        }
        policy.update(self._read_json(POLICY_CONFIG))
        policy.update(self._read_json(POLICY_STATE))
        policy["enabled"] = bool(policy.get("enabled", True))
        policy["targetExposurePct"] = max(0.0, min(float(policy.get("targetExposurePct", 100)), 100.0))
        policy["minimumExposurePct"] = max(0.0, min(float(policy.get("minimumExposurePct", 99.9)), 100.0))
        policy["coreNames"] = max(1, min(int(policy.get("coreNames", 5)), 5))
        policy["executionBufferPct"] = max(0.0, min(float(policy.get("executionBufferPct", 0.05)), 2.0))
        policy["neverIntentionallyFlat"] = bool(policy.get("neverIntentionallyFlat", True))
        policy["targetFilledOrdersPerDay"] = max(1, min(int(policy.get("targetFilledOrdersPerDay", 5)), 20))
        policy["quantityPerOrder"] = max(1, min(int(policy.get("quantityPerOrder", 1)), 100))
        return policy

    def update_policy(self, payload: dict[str, Any]) -> dict[str, Any]:
        policy = self.policy()
        if "enabled" in payload:
            policy["enabled"] = bool(payload["enabled"])
        if "targetFilledOrdersPerDay" in payload:
            policy["targetFilledOrdersPerDay"] = max(1, min(int(payload["targetFilledOrdersPerDay"]), 20))
        POLICY_STATE.parent.mkdir(parents=True, exist_ok=True)
        with POLICY_STATE.open("w", encoding="utf-8") as handle:
            json.dump(
                {
                    "enabled": policy["enabled"],
                    "targetFilledOrdersPerDay": policy["targetFilledOrdersPerDay"],
                },
                handle,
                ensure_ascii=False,
                indent=2,
            )
        self.audit.append(
            "ORDER",
            "MOOMOO_T_POLICY_UPDATED",
            {
                "enabled": policy["enabled"],
                "targetFilledOrdersPerDay": policy["targetFilledOrdersPerDay"],
                "environment": "SIMULATE",
                "liveTradingAllowed": False,
            },
            f"t-policy-{datetime.now().timestamp()}",
        )
        return policy

    @staticmethod
    def _minutes(value: str) -> int:
        hours, minutes = (int(part) for part in value.split(":", 1))
        return hours * 60 + minutes

    @staticmethod
    def _aegis_orders(account: dict[str, Any]) -> list[dict[str, Any]]:
        return [row for row in account.get("orders", []) if str(row.get("remark", "")).startswith("AEGIS_T_")]

    @staticmethod
    def _automation_position(orders: list[dict[str, Any]]) -> tuple[str | None, float]:
        quantities: dict[str, float] = {}
        for row in reversed(orders):
            code = str(row.get("code") or "")
            dealt = float(row.get("dealtQuantity") or 0)
            if row.get("side") == "BUY":
                quantities[code] = quantities.get(code, 0.0) + dealt
            elif row.get("side") == "SELL":
                quantities[code] = quantities.get(code, 0.0) - dealt
        held = [(code, qty) for code, qty in quantities.items() if qty > 0]
        return held[0] if held else (None, 0.0)

    @staticmethod
    def _filled_count(orders: list[dict[str, Any]]) -> int:
        return sum(
            1 for row in orders
            if row.get("status") == "FILLED_ALL" or float(row.get("dealtQuantity") or 0) > 0
        )

    @staticmethod
    def _live_positions(account: dict[str, Any]) -> list[dict[str, Any]]:
        return [
            row for row in account.get("positions", [])
            if float(row.get("quantity") or 0) > 0
        ]

    @staticmethod
    def _core_orders(account: dict[str, Any]) -> list[dict[str, Any]]:
        return [
            row for row in account.get("orders", [])
            if str(row.get("remark") or "").startswith("AEGIS_CORE_")
        ]

    def _enter_full_exposure_core(
        self,
        account: dict[str, Any],
        candidates: list[dict[str, Any]],
        policy: dict[str, Any],
    ) -> dict[str, Any] | None:
        """Build the five-name simulation core when the account is flat.

        The target is 100% NAV. A small execution allowance prevents a quote
        change from creating unintended leverage; whole-share rounding means
        actual exposure can finish just below the target.
        """
        if not policy["neverIntentionallyFlat"]:
            return None
        if self._live_positions(account):
            return None

        core_orders = self._core_orders(account)
        pending = [
            row for row in core_orders
            if row.get("status") not in {"FILLED_ALL", "CANCELLED_ALL", "FAILED", "DISABLED"}
            and float(row.get("dealtQuantity") or 0) < float(row.get("quantity") or 0)
        ]
        if pending:
            return {"action": "SKIP", "reason": "CORE_ORDERS_PENDING"}

        total_assets = float((account.get("funds") or {}).get("totalAssets") or 0)
        available_funds = float((account.get("funds") or {}).get("availableFunds") or 0)
        if total_assets <= 0 or available_funds <= 0:
            return {"action": "SKIP", "reason": "CORE_FUNDS_UNAVAILABLE"}

        selected = [
            row for row in candidates
            if row.get("selected") and row.get("code") in self.gateway.allowed_codes
        ][: policy["coreNames"]]
        if not selected:
            return {"action": "SKIP", "reason": "NO_CORE_CANDIDATES"}

        snapshots = self.gateway.quote_snapshot([str(row["code"]) for row in selected])
        quotes = [
            row for row in snapshots
            if row.get("marketState") in OPEN_MARKET_STATES
            and not row.get("suspended")
            and float(row.get("lastPrice") or 0) > 0
        ]
        if not quotes:
            return {"action": "SKIP", "reason": "CORE_MARKET_NOT_OPEN"}

        target_fraction = policy["targetExposurePct"] / 100.0
        execution_fraction = max(0.0, 1.0 - policy["executionBufferPct"] / 100.0)
        deployable = min(total_assets * target_fraction, available_funds) * execution_fraction
        per_name = deployable / len(quotes)
        submitted: list[dict[str, Any]] = []
        rejected: list[dict[str, Any]] = []
        now = datetime.now(EASTERN_TIME)
        for index, quote in enumerate(quotes, start=1):
            reference_price = max(
                float(quote.get("askPrice") or 0),
                float(quote.get("lastPrice") or 0),
            )
            quantity = math.floor(per_name / reference_price) if reference_price > 0 else 0
            if quantity < 1:
                rejected.append({"code": quote.get("code"), "reason": "ALLOCATION_BELOW_ONE_SHARE"})
                continue
            order = {
                "environment": "SIMULATE",
                "code": quote["code"],
                "side": "BUY",
                "quantity": quantity,
                "price": 0,
                "orderType": "MARKET",
                "remark": f"AEGIS_CORE_FULL_{now.date().isoformat()}_{index}",
            }
            try:
                submitted.append(self.gateway.submit_order(order))
            except Exception as exc:
                rejected.append({"code": quote["code"], "reason": str(exc)})

        result = {
            "action": "FULL_EXPOSURE_ENTRY" if submitted else "SKIP",
            "reason": "CORE_ENTRY_REJECTED" if not submitted else None,
            "orders": submitted,
            "rejected": rejected,
            "targetExposurePct": policy["targetExposurePct"],
            "plannedNotional": round(deployable, 2),
            "rationale": "前五名等权核心仓；目标100%，系统禁止主动空仓",
        }
        self.audit.append(
            "ORDER",
            "MOOMOO_CORE_FULL_EXPOSURE_ENTRY",
            {**result, "environment": "SIMULATE", "liveTradingAllowed": False},
            f"core-full-{now.timestamp()}",
        )
        return result

    def _top_up_full_exposure_core(
        self,
        account: dict[str, Any],
        candidates: list[dict[str, Any]],
        policy: dict[str, Any],
    ) -> dict[str, Any] | None:
        positions = self._live_positions(account)
        if not positions or not policy["neverIntentionallyFlat"]:
            return None
        funds = account.get("funds") or {}
        total_assets = float(funds.get("totalAssets") or 0)
        market_value = float(funds.get("marketValue") or 0)
        available_funds = float(funds.get("availableFunds") or 0)
        if total_assets <= 0:
            return None
        actual_exposure = market_value / total_assets * 100.0
        if actual_exposure >= policy["minimumExposurePct"]:
            return None

        pending = [
            row for row in self._core_orders(account)
            if row.get("status") not in {"FILLED_ALL", "CANCELLED_ALL", "FAILED", "DISABLED"}
            and float(row.get("dealtQuantity") or 0) < float(row.get("quantity") or 0)
        ]
        if pending:
            return {"action": "SKIP", "reason": "CORE_ORDERS_PENDING"}

        selected_codes = {
            str(row.get("code")) for row in candidates
            if row.get("selected") and row.get("code") in self.gateway.allowed_codes
        }
        core_codes = [str(row.get("code")) for row in positions if row.get("code") in selected_codes]
        snapshots = self.gateway.quote_snapshot(core_codes)
        tradable = [
            row for row in snapshots
            if row.get("marketState") in OPEN_MARKET_STATES
            and not row.get("suspended")
            and float(row.get("lastPrice") or 0) > 0
        ]
        if not tradable or available_funds <= 0:
            return {"action": "SKIP", "reason": "CORE_TOP_UP_UNAVAILABLE"}

        # Use the lowest-priced core name to leave the smallest possible
        # whole-share cash remainder.
        quote = min(
            tradable,
            key=lambda row: max(float(row.get("askPrice") or 0), float(row.get("lastPrice") or 0)),
        )
        reference_price = max(float(quote.get("askPrice") or 0), float(quote.get("lastPrice") or 0))
        execution_target_pct = max(
            policy["minimumExposurePct"],
            policy["targetExposurePct"] - policy["executionBufferPct"],
        )
        required = max(0.0, total_assets * execution_target_pct / 100.0 - market_value)
        quantity = math.floor(min(required, available_funds) / reference_price)
        if quantity < 1:
            return None
        now = datetime.now(EASTERN_TIME)
        order = self.gateway.submit_order(
            {
                "environment": "SIMULATE",
                "code": quote["code"],
                "side": "BUY",
                "quantity": quantity,
                "price": 0,
                "orderType": "MARKET",
                "remark": f"AEGIS_CORE_TOPUP_{now.date().isoformat()}",
            }
        )
        result = {
            "action": "FULL_EXPOSURE_TOP_UP",
            "order": order,
            "targetExposurePct": policy["targetExposurePct"],
            "exposureBeforePct": round(actual_exposure, 2),
            "rationale": "核心仓低于99.9%，自动补至接近100%",
        }
        self.audit.append(
            "ORDER",
            "MOOMOO_CORE_FULL_EXPOSURE_TOP_UP",
            {**result, "environment": "SIMULATE", "liveTradingAllowed": False},
            order["traceId"],
        )
        return result

    def _ranked_snapshots(self) -> list[dict[str, Any]]:
        candidates = [
            row for row in self.candidate_provider()
            if row.get("selected")
            and (row.get("tStrategy") or {}).get("enabled")
            and row.get("code") in self.gateway.allowed_codes
        ]
        snapshots = self.gateway.quote_snapshot([str(row["code"]) for row in candidates])
        by_code = {row["code"]: row for row in snapshots}
        ranked = []
        for row in candidates:
            quote = by_code.get(str(row["code"]))
            if not quote or quote.get("suspended") or float(quote.get("lastPrice") or 0) <= 0:
                continue
            last = float(quote.get("lastPrice") or 0)
            t_strategy = row.get("tStrategy") or {}
            buy_at = float(t_strategy.get("buyAtOrBelow") or 0)
            hard_stop = float(t_strategy.get("hardStop") or 0)
            if buy_at <= 0 or last > buy_at or (hard_stop > 0 and last <= hard_stop):
                continue
            average = float(quote.get("averagePrice") or 0)
            previous = float(quote.get("previousClose") or 0)
            intraday = ((last / previous) - 1) if previous > 0 else 0.0
            above_vwap = 1.0 if average > 0 and last >= average else 0.0
            score = (
                float(row.get("technicalScore") or 0) * 0.55
                + float(row.get("probabilityUp") or 0) * 30.0
                + above_vwap * 8.0
                + intraday * 100.0
            )
            ranked.append({**quote, "signal": row, "cadenceScore": round(score, 4)})
        ranked.sort(key=lambda row: row["cadenceScore"], reverse=True)
        return ranked

    def status(self, account: dict[str, Any] | None = None) -> dict[str, Any]:
        policy = self.policy()
        now = datetime.now(EASTERN_TIME)
        filled = self._filled_count(self._aegis_orders(account or {}))
        target = policy["targetFilledOrdersPerDay"]
        funds = (account or {}).get("funds") or {}
        total_assets = float(funds.get("totalAssets") or 0)
        market_value = float(funds.get("marketValue") or 0)
        actual_exposure = (market_value / total_assets * 100.0) if total_assets > 0 else 0.0
        state = "DISCONNECTED"
        market_state = "UNKNOWN"
        next_slot = None
        try:
            candidate = next((row for row in self.candidate_provider() if row.get("code") in self.gateway.allowed_codes), None)
            if candidate and self.gateway.status().get("connected"):
                quotes = self.gateway.quote_snapshot([candidate["code"]])
                market_state = quotes[0]["marketState"] if quotes else "UNKNOWN"
        except Exception:
            market_state = "UNKNOWN"
        current_minute = now.hour * 60 + now.minute
        for slot in policy["scheduleEt"]:
            if self._minutes(slot) > current_minute:
                next_slot = slot
                break
        if not (account or {}).get("connected"):
            state = "DISCONNECTED"
        elif not policy["enabled"]:
            state = "DISABLED"
        elif filled >= target:
            state = "GOAL_COMPLETE"
        elif market_state in OPEN_MARKET_STATES:
            state = "ACTIVE"
        else:
            state = "MARKET_CLOSED"
        return {
            "enabled": policy["enabled"],
            "environment": "SIMULATE",
            "targetFilledOrdersPerDay": target,
            "filledOrdersToday": filled,
            "remaining": max(0, target - filled),
            "progressPct": round(min(100.0, filled / target * 100.0), 1),
            "definition": "5笔为模拟训练目标；只有价格进入该股做T区间才下单，风险平仓可超过目标",
            "targetExposurePct": policy["targetExposurePct"],
            "minimumExposurePct": policy["minimumExposurePct"],
            "actualExposurePct": round(actual_exposure, 2),
            "neverIntentionallyFlat": policy["neverIntentionallyFlat"],
            "coreNames": policy["coreNames"],
            "exposureDefinition": "目标100%核心仓；前五名等权，自动补仓维持99.9%–100%",
            "state": state,
            "marketState": market_state,
            "nextSlotEt": next_slot,
            "scheduleEt": policy["scheduleEt"],
            "flattenEt": policy["flattenEt"],
            "quantityPerOrder": policy["quantityPerOrder"],
            "rules": ["目标仓位100%", "核心仓禁止主动清空", "前五名等权持有", "做T仓独立止盈止损", "仅模拟盘"],
            "runtimeDependency": "本机必须保持开机、联网，Moomoo OpenD必须保持登录",
            "asOfEt": now.isoformat(),
            "liveTradingAllowed": False,
        }

    def tick(self) -> dict[str, Any]:
        if not self._lock.acquire(blocking=False):
            return {"action": "SKIP", "reason": "SCHEDULER_BUSY"}
        try:
            policy = self.policy()
            if not policy["enabled"]:
                return {"action": "SKIP", "reason": "DISABLED"}
            account = self.gateway.account_snapshot()
            now = datetime.now(EASTERN_TIME)
            current_minute = now.hour * 60 + now.minute
            automation_orders = self._aegis_orders(account)
            active = [
                row for row in automation_orders
                if row.get("status") not in {"FILLED_ALL", "CANCELLED_ALL", "FAILED", "DISABLED"}
                and float(row.get("dealtQuantity") or 0) < float(row.get("quantity") or 0)
            ]
            if active:
                return {"action": "SKIP", "reason": "ORDER_PENDING"}
            code_held, quantity_held = self._automation_position(automation_orders)
            filled = self._filled_count(automation_orders)
            candidates = [
                row for row in self.candidate_provider()
                if row.get("selected") and row.get("code") in self.gateway.allowed_codes
            ]
            candidate_by_code = {str(row.get("code")): row for row in candidates}
            market_probe = code_held or next(
                (row.get("code") for row in candidates),
                None,
            )
            quotes = self.gateway.quote_snapshot([market_probe] if market_probe else [])
            market_state = quotes[0]["marketState"] if quotes else "UNKNOWN"
            if market_state not in OPEN_MARKET_STATES:
                return {"action": "SKIP", "reason": f"MARKET_{market_state}"}

            if not code_held:
                core_entry = self._enter_full_exposure_core(account, candidates, policy)
                if core_entry is not None:
                    return core_entry
            core_top_up = self._top_up_full_exposure_core(account, candidates, policy)
            if core_top_up is not None:
                return core_top_up

            exit_reason = None
            if code_held:
                held_signal = candidate_by_code.get(code_held)
                held_plan = (held_signal or {}).get("tStrategy") or {}
                last_price = float((quotes[0] if quotes else {}).get("lastPrice") or 0)
                if current_minute >= self._minutes(policy["flattenEt"]):
                    exit_reason = "收盘前平掉做T训练仓"
                elif held_signal is None:
                    exit_reason = "该股已移出当期进攻候选"
                elif last_price <= float(held_plan.get("hardStop") or 0):
                    exit_reason = "触及个股ATR做T止损位"
                elif last_price >= float(held_plan.get("sellAtOrAbove") or float("inf")):
                    exit_reason = "价格进入个股ATR做T卖出区"
            if code_held and exit_reason:
                result = self.gateway.submit_order(
                    {
                        "environment": "SIMULATE",
                        "code": code_held,
                        "side": "SELL",
                        "quantity": max(1, int(quantity_held)),
                        "price": 0,
                        "orderType": "MARKET",
                        "remark": f"AEGIS_T_EXIT_{now.date().isoformat()}",
                    }
                )
                self.audit.append(
                    "ORDER",
                    "MOOMOO_T_CONDITIONAL_EXIT",
                    {**result, "rationale": exit_reason, "target": policy["targetFilledOrdersPerDay"]},
                    result["traceId"],
                )
                return {
                    "action": "CONDITIONAL_EXIT",
                    "order": result,
                    "rationale": exit_reason,
                }
            if code_held:
                return {"action": "SKIP", "reason": "WAIT_T_SELL_ZONE"}
            if filled >= policy["targetFilledOrdersPerDay"]:
                return {"action": "SKIP", "reason": "GOAL_COMPLETE"}
            due_slots = [slot for slot in policy["scheduleEt"] if self._minutes(slot) <= current_minute]
            if not due_slots:
                return {"action": "SKIP", "reason": "WAITING_FIRST_SLOT"}
            attempts = len(automation_orders)
            if attempts >= policy["maxAttemptsPerDay"]:
                return {"action": "SKIP", "reason": "MAX_ATTEMPTS"}
            if automation_orders:
                last_time = str(automation_orders[0].get("createdAt") or "")
                try:
                    last = datetime.strptime(last_time, "%Y-%m-%d %H:%M:%S").replace(tzinfo=EASTERN_TIME)
                    if (now - last).total_seconds() < policy["minimumRetryMinutes"] * 60:
                        return {"action": "SKIP", "reason": "RETRY_COOLDOWN"}
                except ValueError:
                    pass
            if len(automation_orders) >= len(due_slots) and filled >= len(due_slots):
                return {"action": "SKIP", "reason": "WAITING_NEXT_SLOT"}

            ranked = self._ranked_snapshots()
            if not ranked:
                return {"action": "SKIP", "reason": "NO_STOCK_IN_T_BUY_ZONE"}
            code, side, quantity = ranked[0]["code"], "BUY", policy["quantityPerOrder"]
            t_strategy = (ranked[0].get("signal") or {}).get("tStrategy") or {}
            rationale = f"价格进入个股ATR做T买入区（≤{t_strategy.get('buyAtOrBelow')}）"
            result = self.gateway.submit_order(
                {
                    "environment": "SIMULATE",
                    "code": code,
                    "side": side,
                    "quantity": quantity,
                    "price": 0,
                    "orderType": "MARKET",
                    "remark": f"AEGIS_T_CADENCE_{now.date().isoformat()}_{attempts + 1}",
                }
            )
            self.audit.append(
                "ORDER",
                "MOOMOO_T_CADENCE_ORDER",
                {**result, "rationale": rationale, "target": policy["targetFilledOrdersPerDay"]},
                result["traceId"],
            )
            return {"action": "SUBMITTED", "order": result, "rationale": rationale}
        finally:
            self._lock.release()
