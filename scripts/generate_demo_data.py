#!/usr/bin/env python3
"""Generate deterministic, synthetic artifacts for the public demo.

The output contains no broker, customer, credential or real portfolio data.
It is intentionally small enough to commit and stable enough for CI.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import io
import json
from pathlib import Path
from typing import Any


PROJECT_ROOT = Path(__file__).resolve().parents[1]
UNIVERSE_PATH = PROJECT_ROOT / "config" / "us_universe.json"
OUTPUT_ROOT = PROJECT_ROOT / "demo_data"
DEMO_DATE = "2026-07-20"


def _fraction(token: str, salt: str) -> float:
    digest = hashlib.sha256(f"{salt}:{token}".encode("utf-8")).hexdigest()
    return int(digest[:12], 16) / float(16**12 - 1)


def _csv_text(rows: list[dict[str, Any]], fieldnames: list[str]) -> str:
    buffer = io.StringIO(newline="")
    writer = csv.DictWriter(buffer, fieldnames=fieldnames, lineterminator="\n")
    writer.writeheader()
    writer.writerows(rows)
    return buffer.getvalue()


def _universe() -> list[dict[str, Any]]:
    payload = json.loads(UNIVERSE_PATH.read_text(encoding="utf-8"))
    return [
        row
        for row in payload["securities"]
        if row.get("data_available", True)
        and row.get("tradable", True)
        and str(row.get("code", "")).startswith("US.")
    ]


def build_artifacts() -> dict[str, str]:
    securities = _universe()
    ranked: list[dict[str, Any]] = []
    for row in securities:
        code = str(row["code"])
        score = round(55.0 + 25.0 * _fraction(code, "score"), 3)
        p_up = round(0.47 + 0.12 * _fraction(code, "p-up"), 6)
        p_action = round(0.23 + 0.13 * _fraction(code, "p-action"), 6)
        close = round(35.0 + 465.0 * _fraction(code, "close"), 3)
        atr = round(max(0.5, close * (0.012 + 0.025 * _fraction(code, "atr"))), 3)
        ranked.append(
            {
                "date": DEMO_DATE,
                "code": code,
                "name": row.get("name_en") or row.get("name") or code,
                "close": close,
                "atr14": atr,
                "atr_pct": round(atr / close, 6),
                "amount_ma20": round(25_000_000 + 975_000_000 * _fraction(code, "amount"), 2),
                "market_state": "NEUTRAL",
                "factor_trend": round(40 + 50 * _fraction(code, "trend"), 3),
                "factor_momentum": round(40 + 50 * _fraction(code, "momentum"), 3),
                "factor_relative_strength": round(40 + 50 * _fraction(code, "rs"), 3),
                "factor_volume_price": round(40 + 50 * _fraction(code, "volume"), 3),
                "factor_structure": round(40 + 50 * _fraction(code, "structure"), 3),
                "factor_risk_quality": round(40 + 50 * _fraction(code, "risk"), 3),
                "technical_score": score,
                "base_candidate": str(score >= 62),
                "market_trade_allowed": "True",
                "p_up": p_up,
                "p_action": p_action,
                "calibration_neighbors": 240 + int(500 * _fraction(code, "neighbors")),
                "ranking_value": round(score / 100 * p_up * p_action, 8),
                "selected_signal": "False",
                "trigger_level": round(close + 0.35 * atr, 3),
                "support_level": round(close - 0.75 * atr, 3),
                "invalid_level": round(close - 1.6 * atr, 3),
                "archetype": "Synthetic trend demo",
            }
        )

    ranked.sort(key=lambda item: float(item["ranking_value"]), reverse=True)
    for item in ranked[:5]:
        item["p_up"] = max(float(item["p_up"]), 0.56)
        item["p_action"] = max(float(item["p_action"]), 0.32)
        item["base_candidate"] = "True"
        item["selected_signal"] = "True"
        item["ranking_value"] = round(
            float(item["technical_score"]) / 100
            * float(item["p_up"])
            * float(item["p_action"]),
            8,
        )
    ranked.sort(key=lambda item: float(item["ranking_value"]), reverse=True)

    ledger = [
        {
            "code": row["code"],
            "name": row["name"],
            "first_date": "2021-01-04",
            "last_date": DEMO_DATE,
            "rows": 1395,
            "adjustment": "synthetic",
            "source_url": "synthetic://aegis-forecast/demo",
        }
        for row in ranked
    ]

    predictions: list[dict[str, Any]] = []
    for index in range(300):
        probability = round(0.32 + 0.42 * _fraction(str(index), "calibration-p"), 6)
        actual_threshold = 0.48 + 0.10 * (probability - 0.5)
        label = int(_fraction(str(index), "calibration-label") < actual_threshold)
        predictions.append(
            {
                "date": f"DEMO-{index + 1:03d}",
                "code": ranked[index % len(ranked)]["code"],
                "p_up": probability,
                "label_up": label,
                "selected_signal": str(probability >= 0.56),
            }
        )

    summary = {
        "dataset": "DETERMINISTIC_SYNTHETIC_DEMO",
        "signal_count": 300,
        "evaluated_signal_count": 300,
        "weeks_with_signals": 60,
        "average_names_per_signal_week": 5.0,
        "precision_up": 0.5333,
        "precision_lcb_95": 0.4768,
        "precision_action": 0.31,
        "baseline_up_rate": 0.51,
        "lift_vs_baseline": 1.0457,
        "average_net_return": 0.0042,
        "median_net_return": 0.0031,
        "average_excess_return": 0.0038,
        "profit_factor": 1.18,
        "signal_basket_max_drawdown": -0.142,
        "brier_score": 0.251,
        "ece_5bin": 0.072,
        "average_threshold": 62.0,
    }
    manifest = {
        "kind": "DETERMINISTIC_SYNTHETIC_DEMO",
        "containsBrokerData": False,
        "containsPersonalData": False,
        "containsCredentials": False,
        "asOfLabel": DEMO_DATE,
        "securityCount": len(ranked),
        "description": (
            "Generated locally from the public universe symbols using stable hashes. "
            "Values are illustrative and are not market observations."
        ),
    }

    ranking_fields = [
        "date",
        "code",
        "name",
        "close",
        "atr14",
        "atr_pct",
        "amount_ma20",
        "market_state",
        "factor_trend",
        "factor_momentum",
        "factor_relative_strength",
        "factor_volume_price",
        "factor_structure",
        "factor_risk_quality",
        "technical_score",
        "base_candidate",
        "market_trade_allowed",
        "p_up",
        "p_action",
        "calibration_neighbors",
        "ranking_value",
        "selected_signal",
        "trigger_level",
        "support_level",
        "invalid_level",
        "archetype",
    ]
    return {
        "latest_rankings.csv": _csv_text(ranked, ranking_fields),
        "source_ledger.csv": _csv_text(
            ledger,
            [
                "code",
                "name",
                "first_date",
                "last_date",
                "rows",
                "adjustment",
                "source_url",
            ],
        ),
        "walk_forward_predictions.csv": _csv_text(
            predictions,
            ["date", "code", "p_up", "label_up", "selected_signal"],
        ),
        "backtest_summary.json": json.dumps(
            summary, ensure_ascii=False, indent=2, sort_keys=True
        )
        + "\n",
        "demo_manifest.json": json.dumps(
            manifest, ensure_ascii=False, indent=2, sort_keys=True
        )
        + "\n",
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--check",
        action="store_true",
        help="Fail when committed demo artifacts are missing or stale.",
    )
    args = parser.parse_args()
    expected = build_artifacts()
    if args.check:
        stale = [
            name
            for name, content in expected.items()
            if not (OUTPUT_ROOT / name).exists()
            or (OUTPUT_ROOT / name).read_text(encoding="utf-8") != content
        ]
        if stale:
            raise SystemExit(f"Demo artifacts are missing or stale: {', '.join(stale)}")
        print(f"Demo artifacts verified: {len(expected)} files")
        return

    OUTPUT_ROOT.mkdir(parents=True, exist_ok=True)
    for name, content in expected.items():
        (OUTPUT_ROOT / name).write_text(content, encoding="utf-8", newline="")
    print(f"Generated {len(expected)} deterministic demo artifacts in {OUTPUT_ROOT}")


if __name__ == "__main__":
    main()
