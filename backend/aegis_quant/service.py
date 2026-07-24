from __future__ import annotations

import csv
import json
import math
import os
import subprocess
import sys
import threading
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .audit import AuditLedger
from .learning import LearningRegistry
from .moomoo_gateway import MoomooSimulationGateway
from .nasdaq100_universe import load_universe_config, securities, sync_universe_config
from .paths import APP_ROOT, BACKEND_ROOT, CONFIG_ROOT, STORAGE_ROOT, WORKSPACE_ROOT
from .pnl_ledger import PnLLedger
from .t_trader import SimulationTTrader


MODEL_CONFIG = CONFIG_ROOT / "model_config.json"
PRIVATE_MODEL_ROOT = STORAGE_ROOT / "models" / "nasdaq100"
DEMO_MODEL_ROOT = APP_ROOT / "demo_data"


def _select_model_root() -> Path:
    configured = os.environ.get("AEGIS_MODEL_ROOT")
    if configured:
        return Path(configured).expanduser().resolve()
    if (PRIVATE_MODEL_ROOT / "latest_rankings.csv").exists():
        return PRIVATE_MODEL_ROOT
    return DEMO_MODEL_ROOT


US_MODEL_ROOT = _select_model_root()
DATA_MODE = "DEMO" if US_MODEL_ROOT == DEMO_MODEL_ROOT else "PRIVATE_MODEL_ARTIFACTS"
SOURCE_LEDGER = US_MODEL_ROOT / "source_ledger.csv"
PREDICTIONS = US_MODEL_ROOT / "walk_forward_predictions.csv"
SUMMARY = US_MODEL_ROOT / "backtest_summary.json"
RANKINGS = US_MODEL_ROOT / "latest_rankings.csv"


def _as_float(value: Any, default: float | None = 0.0) -> float | None:
    try:
        number = float(value)
        return number if math.isfinite(number) else default
    except (TypeError, ValueError):
        return default


def _as_int(value: Any, default: int = 0) -> int:
    try:
        return int(float(value))
    except (TypeError, ValueError):
        return default


def _as_bool(value: Any) -> bool:
    return str(value).lower() in {"1", "true", "yes"}


def _price(value: float) -> float:
    return round(max(0.01, float(value)), 3)


def _simulation_execution_opted_in() -> bool:
    return os.environ.get("AEGIS_ENABLE_SIMULATION_EXECUTION", "0").strip().lower() in {
        "1",
        "true",
        "yes",
    }


def _read_csv(path: Path) -> list[dict[str, str]]:
    if not path.exists():
        return []
    with path.open("r", encoding="utf-8", newline="") as handle:
        return list(csv.DictReader(handle))


def _read_json(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


class AegisService:
    """Prediction-only application service.

    The forecasting service is isolated from execution. Moomoo access is
    exposed through a separate simulation-only gateway.
    """

    def __init__(self) -> None:
        self.audit = AuditLedger()
        self.learning = LearningRegistry(audit=self.audit)
        self.pnl = PnLLedger()
        self.moomoo = MoomooSimulationGateway(
            allowed_codes={
                item["code"] for item in self._focus_universe()
                if item.get("tradable", True)
            },
            audit=self.audit,
        )
        self.t_trader = SimulationTTrader(
            self.moomoo,
            lambda: self.signals(limit=50)["items"],
            self.audit,
        )
        self._refresh_lock = threading.Lock()
        self._last_refresh: dict[str, Any] | None = None

    def _config(self) -> dict[str, Any]:
        return _read_json(MODEL_CONFIG)

    def _universe_config(self) -> dict[str, Any]:
        return load_universe_config()

    def _focus_universe(self) -> list[dict[str, Any]]:
        return securities()

    def _market_data_universe(self) -> list[dict[str, Any]]:
        return [
            item
            for item in self._focus_universe()
            if item.get("data_available", True)
            and item.get("tradable", True)
            and str(item.get("code", "")).startswith("US.")
        ]

    def _coverage(self) -> dict[str, Any]:
        ledger = _read_csv(SOURCE_LEDGER)
        allowed_codes = {item["code"].upper() for item in self._market_data_universe()}
        covered_codes = {
            str(row.get("code") or "").upper()
            for row in ledger
            if str(row.get("code") or "").upper() in allowed_codes
        }
        research_universe = len(self._focus_universe())
        market_data_universe = len(allowed_codes)
        covered = len(covered_codes)
        latest_dates = sorted({str(row.get("last_date") or "") for row in ledger if row.get("last_date")})
        return {
            "researchUniverse": research_universe,
            "marketDataUniverse": market_data_universe,
            "coveredSecurities": covered,
            "coveragePct": round((covered / market_data_universe * 100.0), 3) if market_data_universe else 0.0,
            "latestDate": latest_dates[-1] if latest_dates else None,
            "sourceLedgerRows": covered,
            "adjustment": (
                "确定性合成演示数据"
                if DATA_MODE == "DEMO"
                else "美股拆股与分红调整"
            ),
            "dataTier": (
                "Bundled synthetic demo"
                if DATA_MODE == "DEMO"
                else "Moomoo OpenD private artifacts"
            ),
            "fullMarketReady": bool(market_data_universe and covered >= market_data_universe),
            "privateObservationOnly": research_universe - market_data_universe,
        }

    def signals(self, limit: int = 200) -> dict[str, Any]:
        allowed = {item["code"].upper() for item in self._market_data_universe()}
        rows = [
            row for row in _read_csv(RANKINGS)
            if str(row.get("code") or "").upper() in allowed
        ]
        rows.sort(
            key=lambda row: (
                _as_bool(row.get("selected_signal")),
                _as_float(row.get("ranking_value"), 0.0) or 0.0,
            ),
            reverse=True,
        )
        gates = self._config().get("gates", {})
        minimum_p_up = float(gates.get("minimum_p_up", 0.60))
        minimum_p_action = float(gates.get("minimum_p_action", 0.45))
        output = []
        for index, row in enumerate(rows[: max(1, min(int(limit), 500))], start=1):
            market_allowed = _as_bool(row.get("market_trade_allowed"))
            selected = _as_bool(row.get("selected_signal"))
            p_up = _as_float(row.get("p_up"), None)
            p_action = _as_float(row.get("p_action"), None)
            reasons: list[str] = []
            if not market_allowed:
                reasons.append("市场状态门关闭")
            if not _as_bool(row.get("base_candidate")):
                reasons.append("趋势、动量或量价确认不足")
            if p_up is None or p_up < minimum_p_up:
                reasons.append(f"5日上涨校准概率未达到{minimum_p_up:.0%}")
            if p_action is None or p_action < minimum_p_action:
                reasons.append(f"可行动概率未达到{minimum_p_action:.0%}")
            if not reasons and not selected:
                reasons.append("滚动样本外阈值未通过")
            close = _as_float(row.get("close"), 0.0) or 0.0
            atr = _as_float(row.get("atr14"), 0.0) or 0.0
            trigger = _as_float(row.get("trigger_level"), close) or close
            support = _as_float(row.get("support_level"), close - atr) or (close - atr)
            invalid = _as_float(row.get("invalid_level"), close - 2 * atr) or (close - 2 * atr)
            atr = max(atr, close * 0.005)
            pullback_low = max(invalid + 0.25 * atr, support)
            pullback_high = max(pullback_low, min(close, support + 0.60 * atr))
            t_buy = max(invalid + 0.50 * atr, close - 0.45 * atr)
            t_sell = close + 0.45 * atr
            t_stop = max(invalid, close - 1.25 * atr)
            entry_state = (
                "BUY_TRIGGERED" if selected and close >= trigger
                else "WAIT_BREAKOUT" if selected
                else "OBSERVE_ONLY"
            )
            output.append(
                {
                    "rank": index,
                    "date": row.get("date"),
                    "code": str(row.get("code") or "").upper(),
                    "name": row.get("name") or "",
                    "strategy": row.get("archetype") or "趋势评分",
                    "technicalScore": round(_as_float(row.get("technical_score"), 0.0) or 0.0, 1),
                    "probabilityUp": round(p_up, 4) if p_up is not None else None,
                    "probabilityAction": round(p_action, 4) if p_action is not None else None,
                    "sampleCount": _as_int(row.get("calibration_neighbors")),
                    "close": _price(close),
                    "atrPct": round((_as_float(row.get("atr_pct"), 0.0) or 0.0) * 100.0, 2),
                    "amount20": round(_as_float(row.get("amount_ma20"), 0.0) or 0.0, 2),
                    "marketState": row.get("market_state") or "UNKNOWN",
                    "selected": selected,
                    "status": "进攻候选" if selected else "弃权",
                    "rejectionReasons": reasons,
                    "triggerPrice": _price(trigger),
                    "supportPrice": _price(support),
                    "invalidPrice": _price(invalid),
                    "buyPlan": {
                        "state": entry_state,
                        "breakoutEntry": _price(trigger),
                        "pullbackZoneLow": _price(pullback_low),
                        "pullbackZoneHigh": _price(pullback_high),
                        "condition": "放量突破确认价，或回踩区止跌后再入场",
                        "marketGate": "仅 RISK_ON / NEUTRAL 允许新增多头",
                    },
                    "sellPlan": {
                        "hardStop": _price(invalid),
                        "takeProfit1": _price(trigger + 1.0 * atr),
                        "takeProfit2": _price(trigger + 2.0 * atr),
                        "trailingStopAtr": 1.5,
                        "timeStopTradingDays": 5,
                        "rules": [
                            "跌破失效位立即止损",
                            "到达第一目标减仓1/2，剩余仓位用1.5 ATR移动止损",
                            "5个交易日未达预期则时间退出",
                        ],
                    },
                    "tStrategy": {
                        "enabled": selected,
                        "referencePrice": _price(close),
                        "buyAtOrBelow": _price(t_buy),
                        "sellAtOrAbove": _price(t_sell),
                        "hardStop": _price(t_stop),
                        "atr": _price(atr),
                        "maxRoundsPerDay": 2,
                        "positionFractionPerRound": 0.20,
                        "rule": "每轮使用基础仓位的20%；先买后卖，不裸卖空，收盘前平掉训练仓",
                    },
                    "factors": {
                        "趋势": round(_as_float(row.get("factor_trend"), 0.0) or 0.0, 1),
                        "动量": round(_as_float(row.get("factor_momentum"), 0.0) or 0.0, 1),
                        "相对强弱": round(_as_float(row.get("factor_relative_strength"), 0.0) or 0.0, 1),
                        "量价": round(_as_float(row.get("factor_volume_price"), 0.0) or 0.0, 1),
                        "结构": round(_as_float(row.get("factor_structure"), 0.0) or 0.0, 1),
                        "风险质量": round(_as_float(row.get("factor_risk_quality"), 0.0) or 0.0, 1),
                    },
                }
            )
        as_of = output[0]["date"] if output else None
        market_state = output[0]["marketState"] if output else "NOT_READY"
        return {
            "asOf": as_of,
            "marketState": market_state,
            "selectedCount": sum(1 for row in output if row["selected"]),
            "items": output,
            "predictionHorizon": 5,
            "scope": "Nasdaq-100当前成分证券；进攻型纯技术面模型排名",
            "strategyProfile": self._config().get("strategy_profile", "AGGRESSIVE_SIMULATION"),
            "dataMode": DATA_MODE,
            "demoData": DATA_MODE == "DEMO",
        }

    def universe(self, query: str = "", limit: int = 200) -> dict[str, Any]:
        included = [
            {
                **row,
                "included_research": bool(row.get("data_available", True)),
                "market": "US" if str(row.get("code", "")).startswith("US.") else "PRIVATE",
                "trade_environment": "SIMULATE" if row.get("tradable", True) else "OBSERVE_ONLY",
            }
            for row in self._focus_universe()
        ]
        if query:
            token = query.strip().lower()
            included = [
                row
                for row in included
                if token in str(row.get("code", "")).lower()
                or token in str(row.get("name", "")).lower()
            ]
        return {
            "meta": {
                "market": "US",
                "index": self._universe_config().get("index", "NASDAQ-100"),
                "researchUniverse": len(self._focus_universe()),
                "activeUniverse": len(self._market_data_universe()),
                "privateObservationOnly": len(self._focus_universe()) - len(self._market_data_universe()),
                "benchmark": self._universe_config().get("benchmark"),
                "execution": "MOOMOO_SIMULATE_ONLY",
                "constituentAsOf": self._universe_config().get("constituent_as_of"),
                "officialSource": self._universe_config().get("official_source"),
                "constituentCompanies": self._universe_config().get("constituent_company_count", 100),
                "constituentSecurities": len(self._focus_universe()),
                "rankingMethod": self._universe_config().get(
                    "ranking_method", "AEGIS_CURRENT_TECHNICAL_MODEL"
                ),
            },
            "items": included[: max(1, min(int(limit), 500))],
        }

    def sync_universe(self) -> dict[str, Any]:
        trace_id = str(uuid.uuid4())
        config = sync_universe_config()
        self._reload_gateway_universe()
        broker = self.moomoo.status(force_refresh=True)
        result = {
            "ok": True,
            "index": config["index"],
            "constituentSecurities": config["constituent_security_count"],
            "constituentAsOf": config["constituent_as_of"],
            "broker": broker,
            "traceId": trace_id,
        }
        self.audit.append("DATA", "NASDAQ100_UNIVERSE_SYNCED", result, trace_id)
        return result

    def _reload_gateway_universe(self) -> None:
        self.moomoo.set_allowed_codes(
            {
                item["code"]
                for item in self._focus_universe()
                if item.get("tradable", True)
            }
        )

    def moomoo_account(self) -> dict[str, Any]:
        try:
            account = self.moomoo.account_snapshot()
        except Exception as exc:
            broker = self.moomoo.status(force_refresh=True)
            account = {
                "connected": False,
                "broker": "Moomoo",
                "environment": "SIMULATE",
                "account": {"masked": "—", "type": "SIMULATE", "status": broker["state"]},
                "funds": {
                    "currency": "USD",
                    "totalAssets": 0.0,
                    "cash": 0.0,
                    "buyingPower": 0.0,
                    "marketValue": 0.0,
                    "frozenCash": 0.0,
                    "availableFunds": 0.0,
                    "unrealizedPnl": 0.0,
                    "realizedPnl": 0.0,
                    "todayPnl": 0.0,
                },
                "positions": [],
                "orders": [],
                "statistics": {
                    "submittedOrders": 0,
                    "filledOrders": 0,
                    "cancelledOrRejectedOrders": 0,
                    "activeOrders": 0,
                    "buyFilledOrders": 0,
                    "sellFilledOrders": 0,
                    "filledQuantity": 0.0,
                    "turnover": 0.0,
                },
                "asOf": datetime.now(timezone.utc).isoformat(),
                "message": broker.get("message") or str(exc),
                "liveTradingAllowed": False,
            }
        if account.get("connected"):
            self.pnl.record(account)
        account["tTrading"] = self.t_trader.status(account)
        return account

    def pnl_history(self) -> dict[str, Any]:
        return self.pnl.history()

    def update_t_trading(self, payload: dict[str, Any]) -> dict[str, Any]:
        policy = self.t_trader.update_policy(payload)
        account = self.moomoo.account_snapshot()
        return {"ok": True, "policy": policy, "tTrading": self.t_trader.status(account)}

    def run_t_trading_tick(self) -> dict[str, Any]:
        result = self.t_trader.tick()
        try:
            self.pnl.record(self.moomoo.account_snapshot())
        except Exception:
            pass
        return result

    def status(self) -> dict[str, Any]:
        signals = self.signals(limit=200)
        universe_meta = self.universe(limit=20)["meta"]
        coverage = self._coverage()
        metrics = _read_json(SUMMARY)
        evaluated = _as_int(metrics.get("evaluated_signal_count"))
        precision = _as_float(metrics.get("precision_up"), 0.0) or 0.0
        precision_lcb = _as_float(metrics.get("precision_lcb_95"), 0.0) or 0.0
        baseline = _as_float(metrics.get("baseline_up_rate"), 0.0) or 0.0
        average_return = _as_float(metrics.get("average_net_return"), 0.0) or 0.0
        claim_allowed = bool(
            evaluated >= 200
            and average_return > 0
            and precision > baseline
            and precision_lcb > baseline
        )
        conclusion = "优势通过保守检验" if claim_allowed else "尚未证明稳定优势"
        return {
            "system": {
                "name": "Aegis Forecast",
                "version": "1.4.0",
                "mode": "NASDAQ100_SIMULATION",
                "dataMode": DATA_MODE,
                "demoData": DATA_MODE == "DEMO",
                "accountConnected": self.moomoo.status()["connected"],
                "canPlaceOrders": False,
                "canPlaceSimulationOrders": (
                    self.moomoo.status()["connected"]
                    and _simulation_execution_opted_in()
                ),
                "simulationExecutionEnabled": _simulation_execution_opted_in(),
                "liveTradingAllowed": False,
                "serverTime": datetime.now(timezone.utc).isoformat(),
            },
            "market": {
                "state": signals["marketState"],
                "asOf": signals["asOf"],
                "highConfidenceSignals": signals["selectedCount"],
                "researchUniverse": _as_int(universe_meta.get("researchUniverse")),
                "activeUniverse": _as_int(universe_meta.get("activeUniverse")),
                "benchmark": universe_meta.get("benchmark"),
                "execution": universe_meta.get("execution"),
            },
            "coverage": coverage,
            "model": {
                "conclusion": conclusion,
                "evaluatedSignals": evaluated,
                "minimumEvidenceSignals": 200,
                "observedPrecision": round(precision, 4),
                "precisionLowerBound95": round(precision_lcb, 4),
                "baselineUpRate": round(baseline, 4),
                "claimAllowed": claim_allowed,
            },
            "refresh": self._last_refresh,
        }

    def data_status(self) -> dict[str, Any]:
        universe_meta = self.universe(limit=20)["meta"]
        coverage = self._coverage()
        ledger = _read_csv(SOURCE_LEDGER)
        broker = self.moomoo.status()
        market_data_name = (
            "确定性合成演示数据"
            if DATA_MODE == "DEMO"
            else "Moomoo OpenD"
        )
        warnings: list[str] = []
        if not coverage["fullMarketReady"]:
            missing = coverage["marketDataUniverse"] - coverage["coveredSecurities"]
            warnings.append(
                f"有{missing}个Nasdaq-100成分证券尚未达到180条日线要求；暂不参与排名"
            )
        if not broker["connected"]:
            warnings.append(broker["message"])
        return {
            "coverage": coverage,
            "universe": universe_meta,
            "sources": [
                {
                    "name": "Nasdaq官方成分股",
                    "role": "Nasdaq-100当前100家公司、全部成分证券",
                    "status": "AVAILABLE",
                    "updatedAt": self._universe_config().get("constituent_as_of"),
                },
                {
                    "name": market_data_name,
                    "role": (
                        "用于公开复现的合成排名与校准样本"
                        if DATA_MODE == "DEMO"
                        else "美股行情与模拟交易账户"
                    ),
                    "status": (
                        "DEMO"
                        if DATA_MODE == "DEMO"
                        else ("AVAILABLE" if broker["connected"] else "NOT_CONNECTED")
                    ),
                    "updatedAt": coverage.get("latestDate"),
                },
                {
                    "name": "历史日线缓存",
                    "role": "调整后OHLCV与成交额",
                    "status": "AVAILABLE" if coverage["fullMarketReady"] else ("PARTIAL" if ledger else "NOT_READY"),
                    "updatedAt": coverage.get("latestDate"),
                },
            ],
            "warnings": warnings,
            "purchaseRecommendation": (
                "当前为合成演示数据；不得用于投资决策"
                if DATA_MODE == "DEMO"
                else "指数清单来自Nasdaq官方；日线与模拟交易来自Moomoo OpenD"
            ),
            "broker": broker,
            "dataMode": DATA_MODE,
        }

    def performance(self) -> dict[str, Any]:
        metrics = _read_json(SUMMARY)
        rows = _read_csv(PREDICTIONS)
        calibration_rows: list[dict[str, Any]] = []
        buckets = [(0.0, 0.4), (0.4, 0.5), (0.5, 0.6), (0.6, 0.7), (0.7, 1.01)]
        for lower, upper in buckets:
            eligible = []
            for row in rows:
                probability = _as_float(row.get("p_up"), None)
                label = _as_float(row.get("label_up"), None)
                if probability is not None and label is not None and lower <= probability < upper:
                    eligible.append((probability, label))
            if eligible:
                calibration_rows.append(
                    {
                        "bucket": f"{lower:.0%}–{min(upper, 1.0):.0%}",
                        "predicted": round(sum(item[0] for item in eligible) / len(eligible), 4),
                        "actual": round(sum(item[1] for item in eligible) / len(eligible), 4),
                        "samples": len(eligible),
                    }
                )
        evaluated = _as_int(metrics.get("evaluated_signal_count"))
        return {
            "metrics": metrics,
            "calibration": calibration_rows,
            "posture": "EVIDENCE_INSUFFICIENT" if evaluated < 30 else "MONITORING",
            "message": "高置信样本不足，当前结果不可外推" if evaluated < 30 else "继续进行滚动样本外验证",
            "method": "504交易日滚动训练 · 5日标签隔离 · 次日开盘近似进入 · 已计20bp摩擦",
        }

    def factor_status(self) -> dict[str, Any]:
        items = self.signals(limit=200)["items"]
        factor_names = ["趋势", "动量", "相对强弱", "量价", "结构", "风险质量"]
        factors = []
        for name in factor_names:
            values = [float(item["factors"][name]) for item in items]
            factors.append(
                {
                    "name": name,
                    "average": round(sum(values) / len(values), 1) if values else None,
                    "weight": self._factor_weight(name),
                    "description": {
                        "趋势": "均线排列、斜率、ADX与方向性",
                        "动量": "多周期收益、RSI与MACD动能",
                        "相对强弱": "相对纳斯达克100基准的多周期超额",
                        "量价": "量比、OBV、MFI与收盘位置",
                        "结构": "突破、区间位置与波动压缩",
                        "风险质量": "ATR、回撤与成交额可交易性",
                    }[name],
                }
            )
        return {"items": factors, "asOf": items[0]["date"] if items else None}

    def _factor_weight(self, name: str) -> float:
        mapping = {
            "趋势": "trend",
            "动量": "momentum",
            "相对强弱": "relative_strength",
            "量价": "volume_price",
            "结构": "structure",
            "风险质量": "risk_quality",
        }
        value = self._config().get("factor_weights", {}).get(mapping[name], 0.0)
        return round(float(value), 4)

    def refresh_predictions(self) -> dict[str, Any]:
        if not self._refresh_lock.acquire(blocking=False):
            return {"ok": False, "busy": True, "message": "预测刷新正在进行"}
        trace_id = str(uuid.uuid4())
        started = datetime.now(timezone.utc).isoformat()
        self.audit.append("MODEL", "PREDICTION_REFRESH_STARTED", {}, trace_id)
        try:
            broker = self.moomoo.status()
            if not broker["connected"]:
                self._last_refresh = {
                    "ok": False,
                    "startedAt": started,
                    "completedAt": datetime.now(timezone.utc).isoformat(),
                    "message": broker["message"],
                    "traceId": trace_id,
                }
                self.audit.append("MODEL", "PREDICTION_REFRESH_DEFERRED", self._last_refresh, trace_id)
                return self._last_refresh
            local_runtime = APP_ROOT / ".venv" / "bin" / "python"
            python = str(local_runtime if local_runtime.exists() else Path(sys.executable))
            environment = os.environ.copy()
            environment["PYTHONPATH"] = os.pathsep.join(
                [str(BACKEND_ROOT), str(WORKSPACE_ROOT), environment.get("PYTHONPATH", "")]
            )
            completed = subprocess.run(
                [python, "-m", "aegis_quant.us_pipeline"],
                cwd=APP_ROOT,
                capture_output=True,
                text=True,
                timeout=900,
                check=True,
                env=environment,
            )
            result = json.loads(completed.stdout.strip().splitlines()[-1])
            self._reload_gateway_universe()
            self._last_refresh = {
                "ok": True,
                "startedAt": started,
                "completedAt": datetime.now(timezone.utc).isoformat(),
                "message": f"预测已刷新：{result['asOf']}，覆盖{result['rankingRows']}只公开股票",
                "result": result,
                "traceId": trace_id,
            }
            self.audit.append("MODEL", "PREDICTION_REFRESH_COMPLETED", self._last_refresh, trace_id)
            return self._last_refresh
        except Exception as exc:
            self._last_refresh = {
                "ok": False,
                "startedAt": started,
                "completedAt": datetime.now(timezone.utc).isoformat(),
                "message": str(exc),
                "traceId": trace_id,
            }
            self.audit.append("MODEL", "PREDICTION_REFRESH_FAILED", self._last_refresh, trace_id)
            return self._last_refresh
        finally:
            self._refresh_lock.release()

    def audit_events(self) -> dict[str, Any]:
        return {"verification": self.audit.verify(), "items": self.audit.recent(200)}
