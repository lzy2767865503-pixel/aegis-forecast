from __future__ import annotations

import csv
import json
import math
import threading
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .audit import AuditLedger
from .integrity import ScenarioIntegrityRegistry
from .nasdaq100_universe import load_universe_config, securities
from .paths import CONFIG_ROOT, DEMO_ROOT, clear_local_data
from .privacy import PrivacyPreferences
from .runtime_policy import (
    STORE_EDITION,
    STORE_READ_ONLY,
)


MODEL_CONFIG = CONFIG_ROOT / "store_model_config.json"
DEMO_MODEL_ROOT = DEMO_ROOT
US_MODEL_ROOT = DEMO_MODEL_ROOT
DATA_MODE = "DETERMINISTIC_SYNTHETIC_SCENARIO"
SAMPLE_MANIFEST = US_MODEL_ROOT / "illustrative_sample_manifest.csv"
SCENARIO_OUTCOMES = US_MODEL_ROOT / "illustrative_scenario_outcomes.csv"
SCENARIO_METRICS = US_MODEL_ROOT / "scenario_metrics.json"
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


def derive_scenario_metrics(rows: list[dict[str, str]]) -> dict[str, Any]:
    """Derive displayed diagnostics from every bundled illustrative row."""

    parsed = [
        (
            float(row["scenario_up_score"]),
            int(row["illustrative_outcome_up"]),
            _as_bool(row["selected_scenario_case"]),
        )
        for row in rows
    ]
    if not parsed:
        raise ValueError("Bundled illustrative scenario outcomes are missing")
    selected = [(score, outcome) for score, outcome, is_selected in parsed if is_selected]
    buckets = []
    gap = 0.0
    for lower, upper in ((0.0, 0.4), (0.4, 0.5), (0.5, 0.6), (0.6, 0.7), (0.7, 1.01)):
        values = [(score, outcome) for score, outcome, _ in parsed if lower <= score < upper]
        if not values:
            continue
        mean_score = sum(value[0] for value in values) / len(values)
        frequency = sum(value[1] for value in values) / len(values)
        gap += abs(mean_score - frequency) * len(values) / len(parsed)
        buckets.append(
            {
                "bucket": f"{lower:.0%}-{min(upper, 1.0):.0%}",
                "mean_scenario_up_score": round(mean_score, 6),
                "illustrative_up_frequency": round(frequency, 6),
                "sample_count": len(values),
            }
        )
    return {
        "dataset": DATA_MODE,
        "derived_from": SCENARIO_OUTCOMES.name,
        "sample_count": len(parsed),
        "selected_scenario_count": len(selected),
        "mean_scenario_up_score": round(sum(value[0] for value in parsed) / len(parsed), 6),
        "overall_illustrative_up_frequency": round(sum(value[1] for value in parsed) / len(parsed), 6),
        "selected_illustrative_up_frequency": (
            round(sum(value[1] for value in selected) / len(selected), 6)
            if selected
            else None
        ),
        "illustrative_brier_score": round(
            sum((score - outcome) ** 2 for score, outcome, _ in parsed) / len(parsed),
            6,
        ),
        "illustrative_bucket_gap": round(gap, 6),
        "buckets": buckets,
        "claim_boundary": "ILLUSTRATIVE_GENERATED_SAMPLES_ONLY",
    }


class AegisService:
    """Offline Store service for deterministic synthetic research examples."""

    def __init__(self) -> None:
        self.audit = AuditLedger()
        self.integrity = ScenarioIntegrityRegistry(audit=self.audit)
        self.privacy = PrivacyPreferences()
        self._verification_lock = threading.Lock()
        self._last_verification: dict[str, Any] | None = None

    def _config(self) -> dict[str, Any]:
        return _read_json(MODEL_CONFIG)

    def _universe_config(self) -> dict[str, Any]:
        return load_universe_config()

    def _focus_universe(self) -> list[dict[str, Any]]:
        return securities()

    def _scenario_universe(self) -> list[dict[str, Any]]:
        return [
            item
            for item in self._focus_universe()
            if item.get("data_available", True)
            and item.get("research_included", True)
            and str(item.get("code", "")).startswith("US.")
        ]

    def _coverage(self) -> dict[str, Any]:
        sample_manifest = _read_csv(SAMPLE_MANIFEST)
        outcomes = _read_csv(SCENARIO_OUTCOMES)
        allowed_codes = {item["code"].upper() for item in self._scenario_universe()}
        covered_codes = {
            str(row.get("code") or "").upper()
            for row in sample_manifest
            if str(row.get("code") or "").upper() in allowed_codes
        }
        research_universe = len(self._focus_universe())
        scenario_universe = len(allowed_codes)
        covered = len(covered_codes)
        scenario_labels = sorted(
            {
                str(row.get("scenario_as_of") or "")
                for row in sample_manifest
                if row.get("scenario_as_of")
            }
        )
        return {
            "researchUniverse": research_universe,
            "scenarioUniverse": scenario_universe,
            "coveredSecurities": covered,
            "coveragePct": round((covered / scenario_universe * 100.0), 3) if scenario_universe else 0.0,
            "scenarioLabel": scenario_labels[-1] if scenario_labels else None,
            "sampleManifestRows": len(sample_manifest),
            "illustrativeOutcomeRows": len(outcomes),
            "generationMethod": "stable-sha256-v1",
            "dataTier": "Bundled deterministic synthetic scenario",
            "fullScenarioReady": bool(scenario_universe and covered >= scenario_universe),
        }

    def signals(self, limit: int = 200) -> dict[str, Any]:
        allowed = {item["code"].upper() for item in self._scenario_universe()}
        rows = [
            row for row in _read_csv(RANKINGS)
            if str(row.get("code") or "").upper() in allowed
        ]
        rows.sort(
            key=lambda row: (
                _as_bool(row.get("selected_scenario_case")),
                _as_float(row.get("ranking_value"), 0.0) or 0.0,
            ),
            reverse=True,
        )
        gates = self._config().get("gates", {})
        minimum_up_score = float(gates.get("minimum_scenario_up_score", 0.54))
        minimum_pattern_score = float(gates.get("minimum_scenario_pattern_score", 0.30))
        output = []
        for index, row in enumerate(rows[: max(1, min(int(limit), 500))], start=1):
            scenario_context_available = _as_bool(row.get("scenario_context_available"))
            selected = _as_bool(row.get("selected_scenario_case"))
            up_score = _as_float(row.get("scenario_up_score"), None)
            pattern_score = _as_float(row.get("scenario_pattern_score"), None)
            reasons: list[str] = []
            if not scenario_context_available:
                reasons.append("说明性情景字段不完整")
            if not _as_bool(row.get("rule_eligible")):
                reasons.append("稳定哈希情景规则分数不足")
            if up_score is None or up_score < minimum_up_score:
                reasons.append(f"说明性上行分数未达到{minimum_up_score:.0%}")
            if pattern_score is None or pattern_score < minimum_pattern_score:
                reasons.append(f"说明性形态分数未达到{minimum_pattern_score:.0%}")
            if not reasons and not selected:
                reasons.append("说明性选择规则未通过")
            reference = _as_float(row.get("illustrative_reference_value"), 0.0) or 0.0
            variation = _as_float(row.get("illustrative_variation_unit"), 0.0) or 0.0
            trigger = _as_float(row.get("confirmation_reference"), reference) or reference
            support = _as_float(row.get("structural_reference"), reference - variation) or (reference - variation)
            invalid = _as_float(row.get("invalidation_reference"), reference - 2 * variation) or (reference - 2 * variation)
            variation = max(variation, reference * 0.005)
            reference_low = max(invalid + 0.25 * variation, support)
            reference_high = max(reference_low, min(reference, support + 0.60 * variation))
            observation_state = (
                "ABOVE_CONFIRMATION" if selected and reference >= trigger
                else "WAIT_CONFIRMATION" if selected
                else "OBSERVE_ONLY"
            )
            output.append(
                {
                    "rank": index,
                    "date": row.get("scenario_as_of"),
                    "code": str(row.get("code") or "").upper(),
                    "name": row.get("name") or "",
                    "strategy": row.get("archetype") or "趋势评分",
                    "technicalScore": round(_as_float(row.get("technical_score"), 0.0) or 0.0, 1),
                    "scenarioUpScore": round(up_score, 4) if up_score is not None else None,
                    "scenarioPatternScore": round(pattern_score, 4) if pattern_score is not None else None,
                    "illustrativeOutcomeRows": _as_int(row.get("illustrative_outcome_rows")),
                    "referenceValue": _price(reference),
                    "variationPct": round((_as_float(row.get("illustrative_variation_ratio"), 0.0) or 0.0) * 100.0, 2),
                    "activityIndex": round(_as_float(row.get("illustrative_activity_index"), 0.0) or 0.0, 2),
                    "scenarioState": row.get("scenario_state") or "UNKNOWN",
                    "selected": selected,
                    "status": "研究样本" if selected else "证据不足",
                    "rejectionReasons": reasons,
                    "confirmationLevel": _price(trigger),
                    "structuralReferenceLevel": _price(support),
                    "invalidationLevel": _price(invalid),
                    "observationScenario": {
                        "state": observation_state,
                        "confirmationLevel": _price(trigger),
                        "referenceZoneLow": _price(reference_low),
                        "referenceZoneHigh": _price(reference_high),
                        "description": "仅用于展示稳定哈希情景是否达到说明性规则阈值",
                        "marketContext": "ILLUSTRATIVE_NEUTRAL 只是生成标签",
                    },
                    "invalidationScenario": {
                        "invalidationLevel": _price(invalid),
                        "sensitivityLevel1": _price(trigger + 1.0 * variation),
                        "sensitivityLevel2": _price(trigger + 2.0 * variation),
                        "variationSensitivity": 1.5,
                        "notes": [
                            "低于失效参考值时，该说明性生成情景不再成立",
                            "敏感度层1与2只是生成值尺度变化示例",
                            "这些数值没有时间序列、训练或市场含义",
                        ],
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
        scenario_state = output[0]["scenarioState"] if output else "NOT_READY"
        return {
            "asOf": as_of,
            "scenarioState": scenario_state,
            "selectedCount": sum(1 for row in output if row["selected"]),
            "items": output,
            "scope": "Nasdaq-100 2026-08-26 成分证券快照；确定性合成说明性排名",
            "strategyProfile": self._config().get("strategy_profile", "TECHNICAL_RESEARCH_SNAPSHOT"),
            "dataMode": DATA_MODE,
            "demoData": True,
        }

    def universe(self, query: str = "", limit: int = 200) -> dict[str, Any]:
        included = [
            {
                "ticker": row.get("ticker"),
                "code": row.get("code"),
                "name": row.get("name"),
                "name_en": row.get("name_en"),
                "official_name": row.get("official_name"),
                "group": row.get("group"),
                "included_research": bool(row.get("data_available", True)),
                "market": "US",
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
                "scenarioUniverse": len(self._scenario_universe()),
                "benchmark": self._universe_config().get("benchmark"),
                "productMode": "WINDOWS_STORE_READ_ONLY",
                "constituentAsOf": self._universe_config().get("constituent_as_of"),
                "snapshotDate": self._universe_config().get("snapshot_date"),
                "officialSource": self._universe_config().get("official_source"),
                "constituentCompanies": self._universe_config().get("constituent_company_count", 100),
                "constituentSecurities": len(self._focus_universe()),
                "rankingMethod": self._universe_config().get(
                    "ranking_method", "AEGIS_TECHNICAL_RESEARCH_SNAPSHOT"
                ),
            },
            "items": included[: max(1, min(int(limit), 500))],
        }

    def status(self) -> dict[str, Any]:
        signals = self.signals(limit=200)
        universe_meta = self.universe(limit=20)["meta"]
        coverage = self._coverage()
        metrics = derive_scenario_metrics(_read_csv(SCENARIO_OUTCOMES))
        claim_allowed = False
        conclusion = "说明性生成样本；没有真实性能结论"
        return {
            "system": {
                "name": "Aegis Forecast",
                "version": "1.5.0",
                "mode": DATA_MODE,
                "edition": STORE_EDITION,
                "storeReadOnly": STORE_READ_ONLY,
                "dataMode": DATA_MODE,
                "demoData": True,
                "offlineOnly": True,
                "serverTime": datetime.now(timezone.utc).isoformat(),
            },
            "scenario": {
                "state": signals["scenarioState"],
                "asOf": signals["asOf"],
                "selectedScenarioCount": signals["selectedCount"],
                "researchUniverse": _as_int(universe_meta.get("researchUniverse")),
                "scenarioUniverse": _as_int(universe_meta.get("scenarioUniverse")),
                "benchmark": universe_meta.get("benchmark"),
                "productMode": universe_meta.get("productMode"),
            },
            "coverage": coverage,
            "claimBoundary": {
                "conclusion": conclusion,
                "illustrativeSamples": metrics["sample_count"],
                "selectedScenarioSamples": metrics["selected_scenario_count"],
                "selectedIllustrativeUpFrequency": metrics["selected_illustrative_up_frequency"],
                "claimAllowed": claim_allowed,
            },
            "scenarioVerification": self._last_verification,
        }

    def data_status(self) -> dict[str, Any]:
        universe_meta = self.universe(limit=20)["meta"]
        coverage = self._coverage()
        sample_manifest = _read_csv(SAMPLE_MANIFEST)
        warnings: list[str] = []
        if not coverage["fullScenarioReady"]:
            missing = coverage["scenarioUniverse"] - coverage["coveredSecurities"]
            warnings.append(f"有{missing}个成分证券缺少说明性生成行")
        warnings.append("全部数值由稳定哈希生成；没有历史行情、训练数据或真实性能证据")
        return {
            "coverage": coverage,
            "universe": universe_meta,
            "sources": [
                {
                    "name": "Nasdaq官方成分股",
                    "role": "Nasdaq-100 2026-08-26 快照：100家公司、102只成分证券",
                    "status": "AVAILABLE",
                    "updatedAt": self._universe_config().get("constituent_as_of"),
                },
                {
                    "name": "确定性合成说明性情景",
                    "role": "稳定 SHA-256 生成的排名值与说明性结果行",
                    "status": "SYNTHETIC_DEMO",
                    "updatedAt": coverage.get("scenarioLabel"),
                },
                {
                    "name": "说明性样本清单",
                    "role": "每只证券一行生成说明以及300行说明性结果",
                    "status": "AVAILABLE" if coverage["fullScenarioReady"] else ("PARTIAL" if sample_manifest else "NOT_READY"),
                    "updatedAt": coverage.get("scenarioLabel"),
                },
            ],
            "warnings": warnings,
            "purchaseRecommendation": "稳定哈希说明性样本；非市场观测、非训练结果、不得用于投资决策",
            "dataMode": DATA_MODE,
        }

    def performance(self) -> dict[str, Any]:
        metrics = derive_scenario_metrics(_read_csv(SCENARIO_OUTCOMES))
        shipped_metrics = _read_json(SCENARIO_METRICS)
        if metrics != shipped_metrics:
            raise ValueError("Bundled scenario metrics do not match the shipped illustrative rows")
        bucket_rows = [
            {
                "bucket": row["bucket"].replace("-", "–"),
                "scenarioScore": row["mean_scenario_up_score"],
                "illustrativeFrequency": row["illustrative_up_frequency"],
                "samples": row["sample_count"],
            }
            for row in metrics["buckets"]
        ]
        return {
            "metrics": metrics,
            "scenarioBuckets": bucket_rows,
            "posture": "ILLUSTRATIVE_ONLY",
            "message": "结果频率来自随包稳定哈希生成行，只用于验证界面与计算一致性",
            "method": "300行说明性生成样本 · 无历史行情 · 无训练 · 无样本外性能声明",
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
                        "趋势": "稳定哈希生成的说明性趋势维度",
                        "动量": "稳定哈希生成的说明性动量维度",
                        "相对强弱": "稳定哈希生成的说明性相对维度",
                        "量价": "稳定哈希生成的说明性活动维度",
                        "结构": "稳定哈希生成的说明性结构维度",
                        "风险质量": "稳定哈希生成的说明性变化维度",
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

    def verify_scenario(self) -> dict[str, Any]:
        if not self._verification_lock.acquire(blocking=False):
            return {"ok": False, "busy": True, "message": "合成演示校验正在进行"}
        trace_id = str(uuid.uuid4())
        started = datetime.now(timezone.utc).isoformat()
        self.audit.append("SCENARIO", "ILLUSTRATIVE_SCENARIO_CHECK_STARTED", {}, trace_id)
        try:
            metrics = derive_scenario_metrics(_read_csv(SCENARIO_OUTCOMES))
            if metrics != _read_json(SCENARIO_METRICS):
                raise ValueError("说明性生成行与随包指标不一致")
            self._last_verification = {
                "ok": True,
                "startedAt": started,
                "completedAt": datetime.now(timezone.utc).isoformat(),
                "message": "已逐行重算内置说明性生成样本并确认一致；没有行情、训练或账户连接",
                "snapshotDate": "2026-08-26",
                "sampleCount": metrics["sample_count"],
                "traceId": trace_id,
            }
            self.audit.append("SCENARIO", "ILLUSTRATIVE_SCENARIO_CHECK_COMPLETED", self._last_verification, trace_id)
            return self._last_verification
        except Exception as exc:
            self._last_verification = {
                "ok": False,
                "startedAt": started,
                "completedAt": datetime.now(timezone.utc).isoformat(),
                "message": str(exc),
                "traceId": trace_id,
            }
            self.audit.append("SCENARIO", "ILLUSTRATIVE_SCENARIO_CHECK_FAILED", self._last_verification, trace_id)
            return self._last_verification
        finally:
            self._verification_lock.release()

    def audit_events(self) -> dict[str, Any]:
        return {"verification": self.audit.verify(), "items": self.audit.recent(200)}

    def privacy_status(self) -> dict[str, Any]:
        return self.privacy.status()

    def update_privacy(self, payload: dict[str, Any]) -> dict[str, Any]:
        return {"ok": True, "privacy": self.privacy.update(payload)}

    def delete_local_data(self, payload: dict[str, Any]) -> dict[str, Any]:
        if payload.get("confirm") != "DELETE_LOCAL_DATA":
            raise ValueError("Local data deletion requires explicit confirmation")
        result = clear_local_data()
        self.privacy = PrivacyPreferences()
        self.audit = AuditLedger()
        self.integrity = ScenarioIntegrityRegistry(audit=self.audit)
        return {
            **result,
            "message": "Quant Scenario Studio 本地运行数据已删除；合成演示数据和应用文件未受影响",
            "privacy": self.privacy.status(),
        }
