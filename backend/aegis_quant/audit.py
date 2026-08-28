from __future__ import annotations

import hashlib
import json
import sqlite3
from collections.abc import Iterator
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .paths import STORAGE_ROOT, ensure_directories


GENESIS_HASH = "0" * 64


class AuditLedger:
    """Append-only SHA-256 chained operational audit ledger."""

    def __init__(self, database_path: Path | None = None) -> None:
        ensure_directories()
        self.database_path = database_path or STORAGE_ROOT / "operational.db"
        self._initialize()

    @contextmanager
    def connect(self) -> Iterator[sqlite3.Connection]:
        connection = sqlite3.connect(self.database_path, timeout=15)
        try:
            connection.row_factory = sqlite3.Row
            connection.execute("PRAGMA journal_mode=WAL")
            connection.execute("PRAGMA foreign_keys=ON")
            with connection:
                yield connection
        finally:
            connection.close()

    def _initialize(self) -> None:
        with self.connect() as connection:
            connection.execute(
                """
                CREATE TABLE IF NOT EXISTS audit_events (
                    sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                    event_time TEXT NOT NULL,
                    category TEXT NOT NULL,
                    action TEXT NOT NULL,
                    trace_id TEXT NOT NULL,
                    payload_json TEXT NOT NULL,
                    previous_hash TEXT NOT NULL,
                    event_hash TEXT NOT NULL UNIQUE
                )
                """
            )

    def append(
        self,
        category: str,
        action: str,
        payload: dict[str, Any],
        trace_id: str,
    ) -> dict[str, Any]:
        event_time = datetime.now(timezone.utc).isoformat()
        payload_json = json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        with self.connect() as connection:
            last = connection.execute(
                "SELECT event_hash FROM audit_events ORDER BY sequence DESC LIMIT 1"
            ).fetchone()
            previous_hash = last["event_hash"] if last else GENESIS_HASH
            canonical = "|".join(
                [event_time, category, action, trace_id, payload_json, previous_hash]
            )
            event_hash = hashlib.sha256(canonical.encode("utf-8")).hexdigest()
            cursor = connection.execute(
                """
                INSERT INTO audit_events (
                    event_time, category, action, trace_id, payload_json,
                    previous_hash, event_hash
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    event_time,
                    category,
                    action,
                    trace_id,
                    payload_json,
                    previous_hash,
                    event_hash,
                ),
            )
            return {
                "sequence": cursor.lastrowid,
                "eventTime": event_time,
                "category": category,
                "action": action,
                "traceId": trace_id,
                "eventHash": event_hash,
            }

    def recent(self, limit: int = 100) -> list[dict[str, Any]]:
        with self.connect() as connection:
            rows = connection.execute(
                "SELECT * FROM audit_events ORDER BY sequence DESC LIMIT ?", (int(limit),)
            ).fetchall()
        return [
            {
                "sequence": row["sequence"],
                "eventTime": row["event_time"],
                "category": row["category"],
                "action": row["action"],
                "traceId": row["trace_id"],
                "payload": json.loads(row["payload_json"]),
                "previousHash": row["previous_hash"],
                "eventHash": row["event_hash"],
            }
            for row in rows
        ]

    def verify(self) -> dict[str, Any]:
        with self.connect() as connection:
            rows = connection.execute("SELECT * FROM audit_events ORDER BY sequence").fetchall()
        expected_previous = GENESIS_HASH
        for row in rows:
            canonical = "|".join(
                [
                    row["event_time"],
                    row["category"],
                    row["action"],
                    row["trace_id"],
                    row["payload_json"],
                    row["previous_hash"],
                ]
            )
            computed = hashlib.sha256(canonical.encode("utf-8")).hexdigest()
            if row["previous_hash"] != expected_previous or row["event_hash"] != computed:
                return {
                    "valid": False,
                    "events": len(rows),
                    "failedSequence": row["sequence"],
                }
            expected_previous = row["event_hash"]
        return {"valid": True, "events": len(rows), "headHash": expected_previous}
