from __future__ import annotations

import csv
import hashlib
import json
import sqlite3
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .audit import AuditLedger
from .paths import LEGACY_OUTPUTS, STORAGE_ROOT, ensure_directories


PROMOTION_MIN_MATURE_SAMPLES = 2000
PROMOTION_MIN_SIGNAL_SAMPLES = 200
PROMOTION_MIN_SHADOW_DAYS = 60
US_MODEL_ROOT = STORAGE_ROOT / "models" / "nasdaq100"
US_PREDICTIONS = US_MODEL_ROOT / "walk_forward_predictions.csv"
US_SOURCE_LEDGER = US_MODEL_ROOT / "source_ledger.csv"


class LearningRegistry:
    """Governed champion/challenger registry; it never edits live code or risk limits."""

    def __init__(self, database_path: Path | None = None, audit: AuditLedger | None = None) -> None:
        ensure_directories()
        self.database_path = database_path or STORAGE_ROOT / "operational.db"
        self.audit = audit or AuditLedger(self.database_path)
        self._initialize()

    def connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.database_path, timeout=15)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA journal_mode=WAL")
        return connection

    def _initialize(self) -> None:
        with self.connect() as connection:
            connection.executescript(
                """
                CREATE TABLE IF NOT EXISTS model_versions (
                    model_id TEXT PRIMARY KEY,
                    role TEXT NOT NULL,
                    status TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    data_cutoff TEXT,
                    feature_version TEXT NOT NULL,
                    metrics_json TEXT NOT NULL,
                    artifact_hash TEXT NOT NULL,
                    approved_by TEXT
                );
                CREATE TABLE IF NOT EXISTS learning_cycles (
                    cycle_id TEXT PRIMARY KEY,
                    created_at TEXT NOT NULL,
                    status TEXT NOT NULL,
                    mature_samples INTEGER NOT NULL,
                    signal_samples INTEGER NOT NULL,
                    metrics_json TEXT NOT NULL,
                    reasons_json TEXT NOT NULL
                );
                """
            )
            now = datetime.now(timezone.utc).isoformat()
            artifact_hash = hashlib.sha256(b"aegis-us-daily-technical-v1").hexdigest()
            connection.execute(
                """
                INSERT OR IGNORE INTO model_versions (
                    model_id, role, status, created_at, data_cutoff,
                    feature_version, metrics_json, artifact_hash, approved_by
                ) VALUES (?, 'CHAMPION', 'PAPER_ONLY', ?, NULL, 'us-daily-tech-v1', ?, ?, 'SYSTEM_BASELINE')
                """,
                (
                    "aegis-us-daily-technical-v1",
                    now,
                    json.dumps({"precisionClaim": "EVIDENCE_GATED", "market": "US"}, ensure_ascii=False),
                    artifact_hash,
                ),
            )

    def _legacy_evidence(self) -> dict[str, Any]:
        path = US_PREDICTIONS
        if not path.exists():
            return {"matureSamples": 0, "signalSamples": 0, "signalWins": 0, "shadowDays": 0, "years": []}
        mature = 0
        signals = 0
        wins = 0
        year_counts: dict[str, int] = {}
        dates: set[str] = set()
        with path.open("r", encoding="utf-8", newline="") as handle:
            for row in csv.DictReader(handle):
                forward = row.get("forward_return_net")
                if forward in {None, ""}:
                    continue
                mature += 1
                dates.add(str(row.get("date") or ""))
                year = str(row.get("date") or "")[:4]
                year_counts[year] = year_counts.get(year, 0) + 1
                if str(row.get("selected_signal", "")).lower() == "true":
                    signals += 1
                    try:
                        wins += int(float(forward) > 0)
                    except ValueError:
                        pass
        cumulative = 0
        years = []
        for year in sorted(year_counts):
            cumulative += year_counts[year]
            years.append({"year": year, "samples": year_counts[year], "cumulative": cumulative})
        return {
            "matureSamples": mature,
            "signalSamples": signals,
            "signalWins": wins,
            "shadowDays": len({value for value in dates if value}),
            "years": years,
        }

    @staticmethod
    def _coverage() -> str:
        if not US_SOURCE_LEDGER.exists():
            return "0/9"
        with US_SOURCE_LEDGER.open("r", encoding="utf-8", newline="") as handle:
            codes = {
                str(row.get("code") or "") for row in csv.DictReader(handle)
                if str(row.get("code") or "").startswith("US.") and str(row.get("code")) != "US.QQQ"
            }
        return f"{len(codes)}/9"

    def status(self) -> dict[str, Any]:
        evidence = self._legacy_evidence()
        eligible = (
            int(evidence["matureSamples"]) >= PROMOTION_MIN_MATURE_SAMPLES
            and int(evidence["signalSamples"]) >= PROMOTION_MIN_SIGNAL_SAMPLES
            and int(evidence["shadowDays"]) >= PROMOTION_MIN_SHADOW_DAYS
        )
        with self.connect() as connection:
            champion = connection.execute(
                "SELECT * FROM model_versions WHERE role='CHAMPION' ORDER BY created_at DESC LIMIT 1"
            ).fetchone()
            challenger = connection.execute(
                "SELECT * FROM model_versions WHERE role='CHALLENGER' ORDER BY created_at DESC LIMIT 1"
            ).fetchone()
            last_cycle = connection.execute(
                "SELECT * FROM learning_cycles ORDER BY created_at DESC LIMIT 1"
            ).fetchone()
        return {
            "champion": self._model_dict(champion),
            "challenger": self._model_dict(challenger),
            "legacyEvidence": evidence,
            "fullMarketEvidence": {
                "matureSamples": evidence["matureSamples"],
                "signalSamples": evidence["signalSamples"],
                "shadowDays": evidence["shadowDays"],
                "coverage": self._coverage(),
            },
            "promotionGate": {
                "eligible": eligible,
                "minimumMatureSamples": PROMOTION_MIN_MATURE_SAMPLES,
                "minimumSignalSamples": PROMOTION_MIN_SIGNAL_SAMPLES,
                "minimumShadowDays": PROMOTION_MIN_SHADOW_DAYS,
                "humanApprovalRequired": True,
                "liveAutoPromotion": False,
            },
            "drift": {"status": "BASELINE_NOT_ESTABLISHED", "psi": None, "message": "等待全市场日线覆盖与影子预测建立基线"},
            "lastCycle": self._cycle_dict(last_cycle),
        }

    @staticmethod
    def _model_dict(row: sqlite3.Row | None) -> dict[str, Any] | None:
        if not row:
            return None
        return {
            "modelId": row["model_id"],
            "role": row["role"],
            "status": row["status"],
            "createdAt": row["created_at"],
            "dataCutoff": row["data_cutoff"],
            "featureVersion": row["feature_version"],
            "metrics": json.loads(row["metrics_json"]),
            "artifactHash": row["artifact_hash"],
            "approvedBy": row["approved_by"],
        }

    @staticmethod
    def _cycle_dict(row: sqlite3.Row | None) -> dict[str, Any] | None:
        if not row:
            return None
        return {
            "cycleId": row["cycle_id"],
            "createdAt": row["created_at"],
            "status": row["status"],
            "matureSamples": row["mature_samples"],
            "signalSamples": row["signal_samples"],
            "metrics": json.loads(row["metrics_json"]),
            "reasons": json.loads(row["reasons_json"]),
        }

    def run_cycle(self) -> dict[str, Any]:
        evidence = self._legacy_evidence()
        mature = int(evidence["matureSamples"])
        signals = int(evidence["signalSamples"])
        shadow_days = int(evidence["shadowDays"])
        reasons = []
        if mature < PROMOTION_MIN_MATURE_SAMPLES:
            reasons.append(f"成熟样本{mature}，低于晋级门槛{PROMOTION_MIN_MATURE_SAMPLES}")
        if signals < PROMOTION_MIN_SIGNAL_SAMPLES:
            reasons.append(f"高置信信号样本{signals}，低于晋级门槛{PROMOTION_MIN_SIGNAL_SAMPLES}")
        if shadow_days < PROMOTION_MIN_SHADOW_DAYS:
            reasons.append(f"影子验证{shadow_days}日，低于晋级门槛{PROMOTION_MIN_SHADOW_DAYS}日")
        reasons.append("实盘自动晋级被永久禁止，必须人工批准")
        precision = evidence["signalWins"] / signals if signals else None
        metrics = {
            "legacyMatureSamples": mature,
            "legacySignalSamples": signals,
            "legacySignalPrecision": precision,
            "fullMarketMatureSamples": mature,
            "shadowDays": shadow_days,
        }
        cycle_id = str(uuid.uuid4())
        now = datetime.now(timezone.utc).isoformat()
        status = "READY_FOR_HUMAN_REVIEW" if not reasons[:-1] else "BLOCKED_INSUFFICIENT_EVIDENCE"
        with self.connect() as connection:
            connection.execute(
                """
                INSERT INTO learning_cycles (
                    cycle_id, created_at, status, mature_samples,
                    signal_samples, metrics_json, reasons_json
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    cycle_id,
                    now,
                    status,
                    mature,
                    signals,
                    json.dumps(metrics, ensure_ascii=False, sort_keys=True),
                    json.dumps(reasons, ensure_ascii=False),
                ),
            )
        self.audit.append(
            "MODEL",
            "LEARNING_CYCLE_BLOCKED",
            {"cycleId": cycle_id, "status": status, "metrics": metrics, "reasons": reasons},
            cycle_id,
        )
        return self.status()
