from __future__ import annotations

import copy
import importlib
import importlib.util
import math
import os
import subprocess
import threading
import time
import uuid
from dataclasses import dataclass
from datetime import datetime
from typing import Any
from zoneinfo import ZoneInfo

from .audit import AuditLedger


SIMULATE_ENVIRONMENT = "SIMULATE"
SUPPORTED_SIDES = {"BUY", "SELL"}
SUPPORTED_ORDER_TYPES = {"LIMIT", "MARKET"}
EASTERN_TIME = ZoneInfo("America/New_York")


@dataclass(frozen=True)
class GatewayConfig:
    host: str = os.environ.get("AEGIS_MOOMOO_HOST", "127.0.0.1")
    port: int = int(os.environ.get("AEGIS_MOOMOO_PORT", "11111"))
    security_firm: str = os.environ.get("AEGIS_MOOMOO_SECURITY_FIRM", "FUTUMY")


class MoomooSimulationGateway:
    """Moomoo OpenD adapter with a non-bypassable paper-trading boundary.

    Login credentials remain inside OpenD. This process never accepts, stores,
    returns, or logs a Moomoo password or trade-unlock password.
    """

    def __init__(
        self,
        *,
        allowed_codes: set[str],
        config: GatewayConfig | None = None,
        audit: AuditLedger | None = None,
    ) -> None:
        self.allowed_codes = {str(code).upper() for code in allowed_codes}
        self.config = config or GatewayConfig()
        self.audit = audit or AuditLedger()
        # OpenD is a local stateful gateway.  Keep SDK sessions serialized so
        # HTTP requests and the trading scheduler cannot create a connection
        # storm that destabilizes the vendor process.
        self._sdk_lock = threading.RLock()
        self._status_cache: tuple[float, dict[str, Any]] | None = None
        self._account_cache: tuple[float, dict[str, Any]] | None = None
        self._quote_cache: dict[
            tuple[str, ...], tuple[float, list[dict[str, Any]]]
        ] = {}

    @staticmethod
    def assert_simulation_environment(environment: str) -> None:
        if str(environment).upper() != SIMULATE_ENVIRONMENT:
            raise PermissionError("真实交易已被系统永久锁定；只允许 Moomoo 模拟盘")

    def set_allowed_codes(self, codes: set[str]) -> None:
        with self._sdk_lock:
            self.allowed_codes = {str(code).upper() for code in codes}
            self._quote_cache.clear()

    def _sdk_name(self) -> str | None:
        for name in ("moomoo", "futu"):
            if importlib.util.find_spec(name) is not None:
                return name
        return None

    def _opend_process_running(self) -> bool | None:
        """Check local OpenD without opening an invalid empty TCP session."""
        if self.config.host not in {"127.0.0.1", "localhost", "::1"}:
            return None
        try:
            result = subprocess.run(
                ["/usr/bin/pgrep", "-f", "moomoo_OpenD.app/Contents/MacOS/moomoo_OpenD"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=1.0,
                check=False,
            )
            return result.returncode == 0
        except (OSError, subprocess.SubprocessError):
            # On a non-macOS runtime, fall through to the SDK's proper
            # protocol handshake rather than making a raw port probe.
            return None

    @staticmethod
    def _masked_account(account_id: Any) -> str:
        text = str(account_id or "")
        if not text:
            return "—"
        return f"••••{text[-4:]}"

    def _open_context(self, sdk: Any) -> Any:
        firm = getattr(sdk.SecurityFirm, self.config.security_firm, None)
        if firm is None:
            raise RuntimeError(f"不支持的 Moomoo 券商地区：{self.config.security_firm}")
        return sdk.OpenSecTradeContext(
            filter_trdmarket=sdk.TrdMarket.US,
            host=self.config.host,
            port=self.config.port,
            security_firm=firm,
        )

    @staticmethod
    def _has_us_authorization(value: Any) -> bool:
        if value is None:
            return False
        if isinstance(value, (list, tuple, set)):
            values = value
        elif hasattr(value, "tolist"):
            values = value.tolist()
            if not isinstance(values, list):
                values = [values]
        else:
            values = [value]
        return any(
            str(item).strip().upper() in {"US", "TRDMARKET.US"}
            or "'US'" in str(item).upper()
            or '"US"' in str(item).upper()
            for item in values
        )

    def _simulation_accounts(self, sdk: Any) -> tuple[Any, list[dict[str, Any]]]:
        context = self._open_context(sdk)
        try:
            ret, data = context.get_acc_list()
            if ret != sdk.RET_OK:
                raise RuntimeError(str(data))
            records = data.to_dict("records") if hasattr(data, "to_dict") else []
            accounts = [
                row for row in records
                if str(row.get("trd_env", "")).upper() == SIMULATE_ENVIRONMENT
                and self._has_us_authorization(row.get("trdmarket_auth"))
            ]
            return context, accounts
        except Exception:
            context.close()
            raise

    @staticmethod
    def _safe_number(value: Any, default: float = 0.0) -> float:
        try:
            number = float(value)
            return number if math.isfinite(number) else default
        except (TypeError, ValueError):
            return default

    @staticmethod
    def _records(data: Any) -> list[dict[str, Any]]:
        return data.to_dict("records") if hasattr(data, "to_dict") else []

    @staticmethod
    def _enum_text(value: Any) -> str:
        text = str(value or "")
        return text.split(".")[-1].upper()

    @classmethod
    def _order_statistics(cls, orders: list[dict[str, Any]]) -> dict[str, Any]:
        cancelled_tokens = ("CANCEL", "FAIL", "DISABLE", "DELETE", "REJECT")
        terminal_tokens = cancelled_tokens + ("FILLED_ALL",)
        filled_orders = [row for row in orders if cls._safe_number(row.get("dealt_qty")) > 0]
        cancelled = [
            row for row in orders
            if any(token in cls._enum_text(row.get("order_status")) for token in cancelled_tokens)
        ]
        active = [
            row for row in orders
            if not any(token in cls._enum_text(row.get("order_status")) for token in terminal_tokens)
            and cls._safe_number(row.get("dealt_qty")) < cls._safe_number(row.get("qty"))
        ]
        return {
            "submittedOrders": len(orders),
            "filledOrders": len(filled_orders),
            "cancelledOrRejectedOrders": len(cancelled),
            "activeOrders": len(active),
            "buyFilledOrders": sum(
                1 for row in filled_orders if cls._enum_text(row.get("trd_side")) == "BUY"
            ),
            "sellFilledOrders": sum(
                1 for row in filled_orders if cls._enum_text(row.get("trd_side")) == "SELL"
            ),
            "filledQuantity": round(sum(cls._safe_number(row.get("dealt_qty")) for row in orders), 4),
            "turnover": round(
                sum(
                    cls._safe_number(row.get("dealt_qty"))
                    * cls._safe_number(row.get("dealt_avg_price"))
                    for row in orders
                ),
                2,
            ),
        }

    @classmethod
    def _safe_order(cls, row: dict[str, Any]) -> dict[str, Any]:
        order_id = str(row.get("order_id") or "")
        return {
            "orderId": order_id,
            "orderIdMasked": f"••{order_id[-8:]}" if order_id else "—",
            "code": str(row.get("code") or "").upper(),
            "name": str(row.get("stock_name") or ""),
            "side": cls._enum_text(row.get("trd_side")),
            "orderType": cls._enum_text(row.get("order_type")),
            "status": cls._enum_text(row.get("order_status")) or "UNKNOWN",
            "quantity": cls._safe_number(row.get("qty")),
            "price": cls._safe_number(row.get("price")),
            "dealtQuantity": cls._safe_number(row.get("dealt_qty")),
            "dealtAveragePrice": cls._safe_number(row.get("dealt_avg_price")),
            "createdAt": str(row.get("create_time") or ""),
            "updatedAt": str(row.get("updated_time") or ""),
            "lastError": str(row.get("last_err_msg") or ""),
            "remark": str(row.get("remark") or ""),
        }

    def account_snapshot(self, *, force_refresh: bool = False) -> dict[str, Any]:
        with self._sdk_lock:
            now = time.monotonic()
            if (
                not force_refresh
                and self._account_cache is not None
                and now - self._account_cache[0] < 10.0
            ):
                return copy.deepcopy(self._account_cache[1])
            result = self._account_snapshot_uncached()
            self._account_cache = (now, copy.deepcopy(result))
            return copy.deepcopy(result)

    def _account_snapshot_uncached(self) -> dict[str, Any]:
        """Return broker-sourced paper funds, positions and order-derived fills."""
        state = self.status()
        if not state["connected"]:
            raise RuntimeError(state["message"])
        sdk = importlib.import_module(self._sdk_name() or "moomoo")
        context, accounts = self._simulation_accounts(sdk)
        try:
            if not accounts:
                raise RuntimeError("未发现可用的美股模拟账户")
            account = accounts[0]
            account_id = account["acc_id"]
            ret, funds_data = context.accinfo_query(
                trd_env=sdk.TrdEnv.SIMULATE,
                acc_id=account_id,
                refresh_cache=True,
                currency=sdk.Currency.USD,
            )
            if ret != sdk.RET_OK:
                raise RuntimeError(str(funds_data))
            fund_rows = self._records(funds_data)
            fund = fund_rows[0] if fund_rows else {}

            ret, position_data = context.position_list_query(
                trd_env=sdk.TrdEnv.SIMULATE,
                acc_id=account_id,
                refresh_cache=True,
                currency=sdk.Currency.USD,
            )
            if ret != sdk.RET_OK:
                raise RuntimeError(str(position_data))
            positions = []
            for row in self._records(position_data):
                if self._safe_number(row.get("qty")) <= 0:
                    continue
                positions.append(
                    {
                        "code": str(row.get("code") or "").upper(),
                        "name": str(row.get("stock_name") or ""),
                        "quantity": self._safe_number(row.get("qty")),
                        "canSellQuantity": self._safe_number(row.get("can_sell_qty")),
                        "averageCost": self._safe_number(row.get("average_cost") or row.get("cost_price")),
                        "marketValue": self._safe_number(row.get("market_val")),
                        "lastPrice": self._safe_number(row.get("nominal_price")),
                        "unrealizedPnl": self._safe_number(row.get("unrealized_pl") or row.get("pl_val")),
                        "todayPnl": self._safe_number(row.get("today_pl_val")),
                        "pnlRatioPct": self._safe_number(row.get("pl_ratio")),
                        "currency": str(row.get("currency") or "USD"),
                    }
                )

            ret, current_order_data = context.order_list_query(
                trd_env=sdk.TrdEnv.SIMULATE,
                acc_id=account_id,
                refresh_cache=True,
            )
            if ret != sdk.RET_OK:
                raise RuntimeError(str(current_order_data))
            order_rows = self._records(current_order_data)
            eastern_date = datetime.now(EASTERN_TIME).date().isoformat()
            ret, history_order_data = context.history_order_list_query(
                start=eastern_date,
                end=eastern_date,
                trd_env=sdk.TrdEnv.SIMULATE,
                acc_id=account_id,
            )
            if ret == sdk.RET_OK:
                by_id = {str(row.get("order_id") or ""): row for row in order_rows}
                for row in self._records(history_order_data):
                    by_id[str(row.get("order_id") or "")] = row
                order_rows = list(by_id.values())
            order_rows.sort(
                key=lambda row: str(row.get("updated_time") or row.get("create_time") or ""),
                reverse=True,
            )
            orders = [self._safe_order(row) for row in order_rows]
            statistics = self._order_statistics(order_rows)
            position_unrealized = sum(item["unrealizedPnl"] for item in positions)
            position_today = sum(item["todayPnl"] for item in positions)
            return {
                "connected": True,
                "broker": "Moomoo",
                "environment": SIMULATE_ENVIRONMENT,
                "account": {
                    "masked": self._masked_account(account_id),
                    "type": str(account.get("sim_acc_type") or account.get("acc_type") or "SIMULATE"),
                    "status": str(account.get("acc_status") or "UNKNOWN"),
                },
                "funds": {
                    "currency": "USD",
                    "totalAssets": self._safe_number(fund.get("total_assets")),
                    "cash": self._safe_number(fund.get("cash")),
                    "buyingPower": self._safe_number(fund.get("power")),
                    "marketValue": self._safe_number(fund.get("market_val")),
                    "frozenCash": self._safe_number(fund.get("frozen_cash")),
                    "availableFunds": self._safe_number(
                        fund.get("available_funds"), self._safe_number(fund.get("cash"))
                    ),
                    "unrealizedPnl": self._safe_number(fund.get("unrealized_pl"), position_unrealized),
                    "realizedPnl": self._safe_number(fund.get("realized_pl"), 0.0),
                    "todayPnl": position_today,
                },
                "positions": positions,
                "orders": orders,
                "statistics": statistics,
                "asOf": datetime.now().astimezone().isoformat(),
                "provenance": {
                    "funds": "Moomoo OpenD accinfo_query",
                    "positions": "Moomoo OpenD position_list_query",
                    "orders": "Moomoo OpenD order_list_query + history_order_list_query",
                    "fills": "模拟盘不提供独立成交接口；按委托的已成交数量、成交均价和状态派生",
                    "dealApiAvailable": False,
                },
                "liveTradingAllowed": False,
            }
        finally:
            context.close()

    def quote_snapshot(
        self, codes: list[str], *, force_refresh: bool = False
    ) -> list[dict[str, Any]]:
        normalized = tuple(
            str(code).upper()
            for code in codes
            if str(code).upper() in self.allowed_codes
        )
        if not normalized:
            return []
        with self._sdk_lock:
            now = time.monotonic()
            cached = self._quote_cache.get(normalized)
            if not force_refresh and cached is not None and now - cached[0] < 5.0:
                return copy.deepcopy(cached[1])
            result = self._quote_snapshot_uncached(list(normalized))
            self._quote_cache[normalized] = (now, copy.deepcopy(result))
            return copy.deepcopy(result)

    def _quote_snapshot_uncached(self, codes: list[str]) -> list[dict[str, Any]]:
        normalized = [str(code).upper() for code in codes if str(code).upper() in self.allowed_codes]
        if not normalized:
            return []
        sdk = importlib.import_module(self._sdk_name() or "moomoo")
        context = sdk.OpenQuoteContext(host=self.config.host, port=self.config.port)
        try:
            ret, state_data = context.get_market_state(normalized)
            if ret != sdk.RET_OK:
                raise RuntimeError(str(state_data))
            states = {str(row.get("code")): str(row.get("market_state")) for row in self._records(state_data)}
            ret, snapshot_data = context.get_market_snapshot(normalized)
            if ret != sdk.RET_OK:
                raise RuntimeError(str(snapshot_data))
            return [
                {
                    "code": str(row.get("code") or "").upper(),
                    "name": str(row.get("name") or ""),
                    "marketState": states.get(str(row.get("code")), "UNKNOWN"),
                    "lastPrice": self._safe_number(row.get("last_price")),
                    "previousClose": self._safe_number(row.get("prev_close_price")),
                    "averagePrice": self._safe_number(row.get("avg_price")),
                    "bidPrice": self._safe_number(row.get("bid_price")),
                    "askPrice": self._safe_number(row.get("ask_price")),
                    "updatedAt": str(row.get("update_time") or ""),
                    "suspended": bool(row.get("suspension")),
                }
                for row in self._records(snapshot_data)
            ]
        finally:
            context.close()

    def status(self, *, force_refresh: bool = False) -> dict[str, Any]:
        with self._sdk_lock:
            now = time.monotonic()
            if (
                not force_refresh
                and self._status_cache is not None
                and now - self._status_cache[0] < 5.0
            ):
                return copy.deepcopy(self._status_cache[1])
            result = self._status_uncached()
            self._status_cache = (now, copy.deepcopy(result))
            if not result.get("connected"):
                self._account_cache = None
                self._quote_cache.clear()
            return copy.deepcopy(result)

    def _status_uncached(self) -> dict[str, Any]:
        sdk_name = self._sdk_name()
        process_running = self._opend_process_running()
        base = {
            "broker": "Moomoo",
            "market": "US",
            "environment": SIMULATE_ENVIRONMENT,
            "liveTradingAllowed": False,
            "host": self.config.host,
            "port": self.config.port,
            "sdkAvailable": bool(sdk_name),
            "opendReachable": bool(process_running),
            "connected": False,
            "accounts": [],
            "credentialsStoredByAegis": False,
            "requiresSecureOpenDLogin": True,
        }
        if not sdk_name:
            return {**base, "state": "SDK_NOT_INSTALLED", "message": "等待安装 Moomoo OpenAPI SDK"}
        if process_running is False:
            return {**base, "state": "WAITING_OPEND", "message": "等待 Moomoo OpenD 启动并完成登录"}
        try:
            sdk = importlib.import_module(sdk_name)
            context, accounts = self._simulation_accounts(sdk)
            context.close()
            base["opendReachable"] = True
            masked = [
                {
                    "account": self._masked_account(row.get("acc_id")),
                    "type": str(row.get("sim_acc_type") or row.get("acc_type") or "SIMULATE"),
                    "status": str(row.get("acc_status") or "UNKNOWN"),
                }
                for row in accounts
            ]
            if not masked:
                return {**base, "state": "NO_US_SIM_ACCOUNT", "message": "未发现可用的美股模拟账户"}
            return {
                **base,
                "state": "SIMULATION_READY",
                "message": "美股模拟盘已连接",
                "connected": True,
                "accounts": masked,
            }
        except Exception as exc:
            return {**base, "state": "OPEND_ERROR", "message": f"OpenD 尚未就绪：{exc}"}

    def submit_order(self, order: dict[str, Any]) -> dict[str, Any]:
        with self._sdk_lock:
            self._status_cache = None
            try:
                return self._submit_order_uncached(order)
            finally:
                # A submitted paper order changes funds, positions and order
                # statistics; never serve an account cache across submission.
                self._account_cache = None
                self._quote_cache.clear()

    def _submit_order_uncached(self, order: dict[str, Any]) -> dict[str, Any]:
        self.assert_simulation_environment(str(order.get("environment") or SIMULATE_ENVIRONMENT))
        code = str(order.get("code") or "").upper()
        side = str(order.get("side") or "").upper()
        quantity = int(order.get("quantity") or 0)
        price = float(order.get("price") or 0)
        order_type = str(order.get("orderType") or "LIMIT").upper()
        if code not in self.allowed_codes:
            raise ValueError("该股票不在当前 Nasdaq-100 成分证券池内")
        if side not in SUPPORTED_SIDES:
            raise ValueError("模拟单方向只能是 BUY 或 SELL")
        if order_type not in SUPPORTED_ORDER_TYPES:
            raise ValueError("模拟单类型只能是 LIMIT 或 MARKET")
        if quantity <= 0 or (order_type == "LIMIT" and price <= 0):
            raise ValueError("模拟单数量必须大于零；限价单价格必须大于零")

        state = self.status()
        if not state["connected"]:
            raise RuntimeError(state["message"])

        sdk = importlib.import_module(self._sdk_name() or "moomoo")
        context, accounts = self._simulation_accounts(sdk)
        trace_id = str(uuid.uuid4())
        try:
            if not accounts:
                raise RuntimeError("未发现可用的美股模拟账户")
            account_id = accounts[0]["acc_id"]
            trd_side = sdk.TrdSide.BUY if side == "BUY" else sdk.TrdSide.SELL
            sdk_order_type = sdk.OrderType.MARKET if order_type == "MARKET" else sdk.OrderType.NORMAL
            ret, data = context.place_order(
                price=price,
                qty=quantity,
                code=code,
                trd_side=trd_side,
                order_type=sdk_order_type,
                trd_env=sdk.TrdEnv.SIMULATE,
                acc_id=account_id,
                remark=str(order.get("remark") or "AEGIS_MANUAL_SIM")[:64],
            )
            if ret != sdk.RET_OK:
                raise RuntimeError(str(data))
            records = data.to_dict("records") if hasattr(data, "to_dict") else []
            result = records[0] if records else {}
            safe_result = {
                "orderId": str(result.get("order_id") or ""),
                "code": code,
                "side": side,
                "quantity": quantity,
                "price": price,
                "orderType": order_type,
                "status": str(result.get("order_status") or "SUBMITTED"),
                "environment": SIMULATE_ENVIRONMENT,
                "sentToLiveBroker": False,
                "traceId": trace_id,
            }
            self.audit.append("ORDER", "MOOMOO_SIMULATION_ORDER_SUBMITTED", safe_result, trace_id)
            return safe_result
        finally:
            context.close()
