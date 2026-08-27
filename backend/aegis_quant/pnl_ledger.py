"""Disabled financial-snapshot compatibility surface for the Store edition."""

from __future__ import annotations

from datetime import datetime
from pathlib import Path
from typing import Any


class PnLLedger:
    """Never create a database or retain broker-equity information."""

    def __init__(self, database: Path | None = None) -> None:
        # Keep the constructor signature used by older source callers without
        # opening or creating the path.
        self.database = database

    def record(
        self,
        account: dict[str, Any],
        *,
        captured_at: datetime | None = None,
        minimum_interval_seconds: int = 0,
    ) -> None:
        del account, captured_at, minimum_interval_seconds
        raise PermissionError(
            "Windows Store 只读版不保存券商资产、持仓或盈亏快照"
        )

    @staticmethod
    def history(*, as_of: datetime | None = None) -> dict[str, Any]:
        del as_of
        return {
            "disabled": True,
            "source": "WINDOWS_STORE_READ_ONLY",
            "daily": [],
            "periods": {},
            "snapshotCount": 0,
            "limitations": ["券商资产和盈亏快照不写入本地数据库"],
        }
