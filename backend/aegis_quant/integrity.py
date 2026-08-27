"""Local integrity checks for the bundled illustrative scenario.

The Store edition does not train, compare, promote, or replace models. This
module records only deterministic checks of the files shipped with the app.
"""

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
from .paths import DEMO_ROOT, STORAGE_ROOT, ensure_directories


SCENARIO_OUTCOMES = DEMO_ROOT / "illustrative_scenario_outcomes.csv"
SCENARIO_METRICS = DEMO_ROOT / "scenario_metrics.json"


class ScenarioIntegrityRegistry:
    """Record local scenario-integrity checks without any learning behavior."""

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
            connection.execute(
                """
                CREATE TABLE IF NOT EXISTS scenario_integrity_checks (
                    check_id TEXT PRIMARY KEY,
                    created_at TEXT NOT NULL,
                    status TEXT NOT NULL,
                    sample_count INTEGER NOT NULL,
                    selected_count INTEGER NOT NULL,
                    outcomes_sha256 TEXT NOT NULL,
                    metrics_sha256 TEXT NOT NULL,
                    details_json TEXT NOT NULL
                )
                """
            )

    @staticmethod
    def _evidence() -> dict[str, Any]:
        with SCENARIO_OUTCOMES.open("r", encoding="utf-8", newline="") as handle:
            rows = list(csv.DictReader(handle))
        selected = sum(
            str(row.get("selected_scenario_case", "")).lower() == "true"
            for row in rows
        )
        methods = sorted({str(row.get("generation_method") or "") for row in rows})
        return {
            "sampleCount": len(rows),
            "selectedScenarioCount": selected,
            "generationMethods": methods,
            "outcomesSha256": hashlib.sha256(SCENARIO_OUTCOMES.read_bytes()).hexdigest(),
            "metricsSha256": hashlib.sha256(SCENARIO_METRICS.read_bytes()).hexdigest(),
            "claimBoundary": "ILLUSTRATIVE_GENERATED_SAMPLES_ONLY",
        }

    def status(self) -> dict[str, Any]:
        evidence = self._evidence()
        with self.connect() as connection:
            row = connection.execute(
                "SELECT * FROM scenario_integrity_checks ORDER BY created_at DESC LIMIT 1"
            ).fetchone()
        last_check = None
        if row:
            last_check = {
                "checkId": row["check_id"],
                "createdAt": row["created_at"],
                "status": row["status"],
                "sampleCount": row["sample_count"],
                "selectedScenarioCount": row["selected_count"],
                "details": json.loads(row["details_json"]),
            }
        return {
            "referenceConfiguration": {
                "id": "deterministic-scenario-v1",
                "status": "LOCKED_ILLUSTRATIVE_CONFIGURATION",
                "author": "LAI ZEYU（来泽宇）",
            },
            "illustrativeEvidence": evidence,
            "replacementPolicy": {
                "trainsModels": False,
                "comparesModels": False,
                "automaticReplacement": False,
                "executionCapability": False,
            },
            "lastCheck": last_check,
        }

    def run_cycle(self) -> dict[str, Any]:
        evidence = self._evidence()
        expected_methods = ["stable-sha256-v1"]
        if evidence["sampleCount"] != 300:
            raise ValueError("Expected exactly 300 bundled illustrative outcome rows")
        if evidence["generationMethods"] != expected_methods:
            raise ValueError("Unexpected illustrative scenario generation method")
        check_id = str(uuid.uuid4())
        now = datetime.now(timezone.utc).isoformat()
        details = {
            "message": "随包说明性生成样本完整性已核对；没有训练、比较或模型替换",
            "claimBoundary": evidence["claimBoundary"],
        }
        with self.connect() as connection:
            connection.execute(
                """
                INSERT INTO scenario_integrity_checks (
                    check_id, created_at, status, sample_count, selected_count,
                    outcomes_sha256, metrics_sha256, details_json
                ) VALUES (?, ?, 'ILLUSTRATIVE_FILES_VERIFIED', ?, ?, ?, ?, ?)
                """,
                (
                    check_id,
                    now,
                    evidence["sampleCount"],
                    evidence["selectedScenarioCount"],
                    evidence["outcomesSha256"],
                    evidence["metricsSha256"],
                    json.dumps(details, ensure_ascii=False, sort_keys=True),
                ),
            )
        self.audit.append(
            "SCENARIO",
            "ILLUSTRATIVE_FILES_VERIFIED",
            {"checkId": check_id, **evidence},
            check_id,
        )
        return self.status()
