from __future__ import annotations

import sqlite3
from collections import defaultdict
from datetime import date, datetime, time, timezone
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo

from .paths import STORAGE_ROOT, ensure_directories


EASTERN_TIME = ZoneInfo("America/New_York")


class PnLLedger:
    """Persistent broker-equity snapshots and calendar P&L rollups."""

    def __init__(self, database_path: Path | None = None) -> None:
        ensure_directories()
        self.database_path = database_path or STORAGE_ROOT / "operational.db"
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
                CREATE TABLE IF NOT EXISTS broker_equity_snapshots (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    captured_at_utc TEXT NOT NULL,
                    trading_date_et TEXT NOT NULL,
                    snapshot_kind TEXT NOT NULL,
                    total_assets REAL NOT NULL,
                    cash REAL NOT NULL,
                    market_value REAL NOT NULL,
                    broker_today_pnl REAL NOT NULL,
                    source TEXT NOT NULL
                )
                """
            )
            connection.execute(
                """
                CREATE UNIQUE INDEX IF NOT EXISTS one_daily_opening_baseline
                ON broker_equity_snapshots(trading_date_et, snapshot_kind)
                WHERE snapshot_kind = 'OPENING_BASELINE'
                """
            )
            connection.execute(
                """
                CREATE INDEX IF NOT EXISTS equity_snapshots_by_date_time
                ON broker_equity_snapshots(trading_date_et, captured_at_utc)
                """
            )

    @staticmethod
    def _number(value: Any) -> float:
        try:
            return float(value or 0)
        except (TypeError, ValueError):
            return 0.0

    def record(
        self,
        account: dict[str, Any],
        *,
        captured_at: datetime | None = None,
        minimum_interval_seconds: int = 300,
    ) -> dict[str, Any]:
        if not account.get("connected"):
            return {"recorded": False, "reason": "BROKER_NOT_CONNECTED"}
        funds = account.get("funds") or {}
        total_assets = self._number(funds.get("totalAssets"))
        if total_assets <= 0:
            return {"recorded": False, "reason": "TOTAL_ASSETS_UNAVAILABLE"}

        now = captured_at or datetime.now(timezone.utc)
        if now.tzinfo is None:
            now = now.replace(tzinfo=timezone.utc)
        now = now.astimezone(timezone.utc)
        eastern_now = now.astimezone(EASTERN_TIME)
        trading_date = eastern_now.date().isoformat()
        cash = self._number(funds.get("cash"))
        market_value = self._number(funds.get("marketValue"))
        today_pnl = self._number(funds.get("todayPnl"))

        with self.connect() as connection:
            opening = connection.execute(
                """
                SELECT id FROM broker_equity_snapshots
                WHERE trading_date_et=? AND snapshot_kind='OPENING_BASELINE'
                LIMIT 1
                """,
                (trading_date,),
            ).fetchone()
            if opening is None:
                opening_et = datetime.combine(eastern_now.date(), time.min, tzinfo=EASTERN_TIME)
                opening_assets = total_assets - today_pnl
                connection.execute(
                    """
                    INSERT OR IGNORE INTO broker_equity_snapshots (
                        captured_at_utc, trading_date_et, snapshot_kind,
                        total_assets, cash, market_value, broker_today_pnl, source
                    ) VALUES (?, ?, 'OPENING_BASELINE', ?, ?, ?, 0, ?)
                    """,
                    (
                        opening_et.astimezone(timezone.utc).isoformat(),
                        trading_date,
                        opening_assets,
                        cash,
                        max(0.0, opening_assets - cash),
                        "MOOMOO_DERIVED_FROM_TODAY_PNL",
                    ),
                )

            last = connection.execute(
                """
                SELECT captured_at_utc, total_assets, cash, market_value
                FROM broker_equity_snapshots
                WHERE snapshot_kind='SNAPSHOT'
                ORDER BY captured_at_utc DESC LIMIT 1
                """
            ).fetchone()
            if last is not None and minimum_interval_seconds > 0:
                last_at = datetime.fromisoformat(last["captured_at_utc"])
                age = (now - last_at).total_seconds()
                if age < minimum_interval_seconds:
                    return {"recorded": False, "reason": "INTERVAL_NOT_DUE"}

            connection.execute(
                """
                INSERT INTO broker_equity_snapshots (
                    captured_at_utc, trading_date_et, snapshot_kind,
                    total_assets, cash, market_value, broker_today_pnl, source
                ) VALUES (?, ?, 'SNAPSHOT', ?, ?, ?, ?, 'MOOMOO_OPEND')
                """,
                (
                    now.isoformat(),
                    trading_date,
                    total_assets,
                    cash,
                    market_value,
                    today_pnl,
                ),
            )
        return {"recorded": True, "tradingDateEt": trading_date, "totalAssets": total_assets}

    @staticmethod
    def _period(
        label: str,
        start_date: date,
        end_date: date,
        daily: list[dict[str, Any]],
        coverage_start: date | None,
    ) -> dict[str, Any]:
        rows = [row for row in daily if start_date.isoformat() <= row["date"] <= end_date.isoformat()]
        profit = round(sum(float(row["profit"]) for row in rows), 2)
        opening_assets = float(rows[0]["openingAssets"]) if rows else 0.0
        ending_assets = float(rows[-1]["endingAssets"]) if rows else 0.0
        return_pct = round(profit / opening_assets * 100.0, 4) if opening_assets else 0.0
        return {
            "label": label,
            "startDate": start_date.isoformat(),
            "endDate": end_date.isoformat(),
            "profit": profit,
            "returnPct": return_pct,
            "openingAssets": round(opening_assets, 2),
            "endingAssets": round(ending_assets, 2),
            "tradingDays": len(rows),
            "partialCoverage": coverage_start is None or coverage_start > start_date,
        }

    def history(self, *, as_of: datetime | None = None, daily_limit: int = 366) -> dict[str, Any]:
        now = as_of or datetime.now(timezone.utc)
        if now.tzinfo is None:
            now = now.replace(tzinfo=timezone.utc)
        local_date = now.astimezone(EASTERN_TIME).date()
        with self.connect() as connection:
            rows = connection.execute(
                """
                SELECT * FROM broker_equity_snapshots
                ORDER BY trading_date_et, captured_at_utc
                """
            ).fetchall()

        grouped: dict[str, list[sqlite3.Row]] = defaultdict(list)
        for row in rows:
            grouped[str(row["trading_date_et"])].append(row)
        daily: list[dict[str, Any]] = []
        for trading_date, day_rows in sorted(grouped.items()):
            opening_row = next(
                (row for row in day_rows if row["snapshot_kind"] == "OPENING_BASELINE"),
                day_rows[0],
            )
            snapshots = [row for row in day_rows if row["snapshot_kind"] == "SNAPSHOT"]
            ending_row = snapshots[-1] if snapshots else day_rows[-1]
            opening_assets = float(opening_row["total_assets"])
            ending_assets = float(ending_row["total_assets"])
            profit = ending_assets - opening_assets
            daily.append(
                {
                    "date": trading_date,
                    "openingAssets": round(opening_assets, 2),
                    "endingAssets": round(ending_assets, 2),
                    "profit": round(profit, 2),
                    "returnPct": round(profit / opening_assets * 100.0, 4) if opening_assets else 0.0,
                    "cash": round(float(ending_row["cash"]), 2),
                    "marketValue": round(float(ending_row["market_value"]), 2),
                    "snapshots": len(snapshots),
                    "lastSnapshotAt": ending_row["captured_at_utc"],
                }
            )

        coverage_start = date.fromisoformat(daily[0]["date"]) if daily else None
        week_start = local_date.fromordinal(local_date.toordinal() - local_date.weekday())
        month_start = local_date.replace(day=1)
        year_start = local_date.replace(month=1, day=1)
        latest = daily[-1] if daily else None
        periods = {
            "day": self._period("今日", local_date, local_date, daily, coverage_start),
            "week": self._period("本周", week_start, local_date, daily, coverage_start),
            "month": self._period("本月", month_start, local_date, daily, coverage_start),
            "year": self._period("本年", year_start, local_date, daily, coverage_start),
        }
        return {
            "source": "Moomoo OpenD 模拟账户总资产",
            "timezone": "America/New_York",
            "calculation": "每日盈利=当日最新总资产-当日开盘基准；周/月/年为每日盈利之和",
            "coverageStartDate": coverage_start.isoformat() if coverage_start else None,
            "latestSnapshotAt": latest["lastSnapshotAt"] if latest else None,
            "snapshotCount": sum(row["snapshots"] for row in daily),
            "periods": periods,
            "daily": list(reversed(daily[-max(1, int(daily_limit)):])),
            "limitations": [
                "启用记录前的历史无法回补",
                "入金或出金会被视为净值变化，当前模拟账户未接入资金流水调整",
                "当日与当前周期数据会随行情变化",
            ],
            "liveTradingAllowed": False,
        }
