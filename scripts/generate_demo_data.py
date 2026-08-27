#!/usr/bin/env python3
"""Generate the bundled deterministic synthetic scenario.

Every numeric value is produced from stable SHA-256 hashes. The artifacts are
illustrative generated samples, not observations, training output, a backtest,
or evidence of predictive performance.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import io
import json
from collections import Counter
from pathlib import Path
from typing import Any


PROJECT_ROOT = Path(__file__).resolve().parents[1]
UNIVERSE_PATH = PROJECT_ROOT / "config" / "us_universe.json"
OUTPUT_ROOT = PROJECT_ROOT / "demo_data"
SCENARIO_LABEL = "2026-08-26"
SCENARIO_KIND = "DETERMINISTIC_SYNTHETIC_SCENARIO"
LEGACY_FILENAMES = {
    "backtest_summary.json",
    "source_ledger.csv",
    "walk_forward_predictions.csv",
}


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
        and row.get("research_included", True)
        and str(row.get("code", "")).startswith("US.")
    ]


def derive_scenario_metrics(rows: list[dict[str, Any]]) -> dict[str, Any]:
    """Compute every displayed metric from the shipped illustrative rows."""

    if not rows:
        raise ValueError("At least one illustrative scenario row is required")
    scores = [float(row["scenario_up_score"]) for row in rows]
    outcomes = [int(row["illustrative_outcome_up"]) for row in rows]
    selected = [
        (score, outcome)
        for score, outcome, row in zip(scores, outcomes, rows)
        if str(row["selected_scenario_case"]).lower() == "true"
    ]
    brier = sum((score - outcome) ** 2 for score, outcome in zip(scores, outcomes)) / len(rows)

    bucket_rows: list[dict[str, Any]] = []
    bucket_gap = 0.0
    for lower, upper in ((0.0, 0.4), (0.4, 0.5), (0.5, 0.6), (0.6, 0.7), (0.7, 1.01)):
        values = [
            (score, outcome)
            for score, outcome in zip(scores, outcomes)
            if lower <= score < upper
        ]
        if not values:
            continue
        mean_score = sum(item[0] for item in values) / len(values)
        outcome_frequency = sum(item[1] for item in values) / len(values)
        bucket_gap += abs(mean_score - outcome_frequency) * len(values) / len(rows)
        bucket_rows.append(
            {
                "bucket": f"{lower:.0%}-{min(upper, 1.0):.0%}",
                "mean_scenario_up_score": round(mean_score, 6),
                "illustrative_up_frequency": round(outcome_frequency, 6),
                "sample_count": len(values),
            }
        )

    return {
        "dataset": SCENARIO_KIND,
        "derived_from": "illustrative_scenario_outcomes.csv",
        "sample_count": len(rows),
        "selected_scenario_count": len(selected),
        "mean_scenario_up_score": round(sum(scores) / len(scores), 6),
        "overall_illustrative_up_frequency": round(sum(outcomes) / len(outcomes), 6),
        "selected_illustrative_up_frequency": (
            round(sum(item[1] for item in selected) / len(selected), 6)
            if selected
            else None
        ),
        "illustrative_brier_score": round(brier, 6),
        "illustrative_bucket_gap": round(bucket_gap, 6),
        "buckets": bucket_rows,
        "claim_boundary": "ILLUSTRATIVE_GENERATED_SAMPLES_ONLY",
    }


def build_artifacts() -> dict[str, str]:
    securities = _universe()
    codes = [str(row["code"]) for row in securities]

    outcomes: list[dict[str, Any]] = []
    for index in range(300):
        score = round(0.32 + 0.42 * _fraction(str(index), "scenario-up-score"), 6)
        threshold = 0.48 + 0.10 * (score - 0.5)
        outcome = int(_fraction(str(index), "illustrative-outcome") < threshold)
        outcomes.append(
            {
                "sample_id": f"SYNTH-{index + 1:03d}",
                "code": codes[index % len(codes)],
                "scenario_up_score": score,
                "illustrative_outcome_up": outcome,
                "selected_scenario_case": str(score >= 0.56),
                "generation_method": "stable-sha256-v1",
            }
        )
    outcome_counts = Counter(str(row["code"]) for row in outcomes)

    ranked: list[dict[str, Any]] = []
    for row in securities:
        code = str(row["code"])
        score = round(55.0 + 25.0 * _fraction(code, "technical-score"), 3)
        up_score = round(0.47 + 0.12 * _fraction(code, "scenario-up-score"), 6)
        pattern_score = round(0.23 + 0.13 * _fraction(code, "scenario-pattern-score"), 6)
        reference = round(35.0 + 465.0 * _fraction(code, "reference-value"), 3)
        variation = round(max(0.5, reference * (0.012 + 0.025 * _fraction(code, "variation"))), 3)
        ranked.append(
            {
                "scenario_as_of": SCENARIO_LABEL,
                "code": code,
                "name": row.get("name_en") or row.get("name") or code,
                "illustrative_reference_value": reference,
                "illustrative_variation_unit": variation,
                "illustrative_variation_ratio": round(variation / reference, 6),
                "illustrative_activity_index": round(20 + 80 * _fraction(code, "activity-index"), 3),
                "scenario_state": "ILLUSTRATIVE_NEUTRAL",
                "factor_trend": round(40 + 50 * _fraction(code, "trend"), 3),
                "factor_momentum": round(40 + 50 * _fraction(code, "momentum"), 3),
                "factor_relative_strength": round(40 + 50 * _fraction(code, "relative-strength"), 3),
                "factor_volume_price": round(40 + 50 * _fraction(code, "volume-price"), 3),
                "factor_structure": round(40 + 50 * _fraction(code, "structure"), 3),
                "factor_risk_quality": round(40 + 50 * _fraction(code, "risk-quality"), 3),
                "technical_score": score,
                "rule_eligible": str(score >= 62),
                "scenario_context_available": "True",
                "scenario_up_score": up_score,
                "scenario_pattern_score": pattern_score,
                "illustrative_outcome_rows": outcome_counts[code],
                "ranking_value": round(score / 100 * up_score * pattern_score, 8),
                "selected_scenario_case": "False",
                "confirmation_reference": round(reference + 0.35 * variation, 3),
                "structural_reference": round(reference - 0.75 * variation, 3),
                "invalidation_reference": round(reference - 1.6 * variation, 3),
                "archetype": "Stable-hash illustrative trend scenario",
            }
        )

    ranked.sort(key=lambda item: float(item["ranking_value"]), reverse=True)
    for item in ranked[:5]:
        item["scenario_up_score"] = max(float(item["scenario_up_score"]), 0.56)
        item["scenario_pattern_score"] = max(float(item["scenario_pattern_score"]), 0.32)
        item["rule_eligible"] = "True"
        item["selected_scenario_case"] = "True"
        item["ranking_value"] = round(
            float(item["technical_score"])
            / 100
            * float(item["scenario_up_score"])
            * float(item["scenario_pattern_score"]),
            8,
        )
    ranked.sort(key=lambda item: float(item["ranking_value"]), reverse=True)

    sample_manifest = [
        {
            "code": row["code"],
            "name": row["name"],
            "scenario_as_of": SCENARIO_LABEL,
            "ranking_rows": 1,
            "illustrative_outcome_rows": outcome_counts[str(row["code"])],
            "source_kind": "STABLE_HASH_GENERATED",
            "generator": "scripts/generate_demo_data.py",
        }
        for row in ranked
    ]
    metrics = derive_scenario_metrics(outcomes)
    manifest = {
        "kind": SCENARIO_KIND,
        "containsBrokerData": False,
        "containsPersonalData": False,
        "containsCredentials": False,
        "containsMarketObservations": False,
        "containsTrainingOutput": False,
        "asOfLabel": SCENARIO_LABEL,
        "securityCount": len(ranked),
        "illustrativeOutcomeSamples": len(outcomes),
        "description": (
            "Generated locally from public universe symbols using stable SHA-256 hashes. "
            "Every numeric value is illustrative and is not a market observation, model "
            "training result, backtest, or performance claim."
        ),
    }

    ranking_fields = [
        "scenario_as_of",
        "code",
        "name",
        "illustrative_reference_value",
        "illustrative_variation_unit",
        "illustrative_variation_ratio",
        "illustrative_activity_index",
        "scenario_state",
        "factor_trend",
        "factor_momentum",
        "factor_relative_strength",
        "factor_volume_price",
        "factor_structure",
        "factor_risk_quality",
        "technical_score",
        "rule_eligible",
        "scenario_context_available",
        "scenario_up_score",
        "scenario_pattern_score",
        "illustrative_outcome_rows",
        "ranking_value",
        "selected_scenario_case",
        "confirmation_reference",
        "structural_reference",
        "invalidation_reference",
        "archetype",
    ]
    return {
        "latest_rankings.csv": _csv_text(ranked, ranking_fields),
        "illustrative_sample_manifest.csv": _csv_text(
            sample_manifest,
            [
                "code",
                "name",
                "scenario_as_of",
                "ranking_rows",
                "illustrative_outcome_rows",
                "source_kind",
                "generator",
            ],
        ),
        "illustrative_scenario_outcomes.csv": _csv_text(
            outcomes,
            [
                "sample_id",
                "code",
                "scenario_up_score",
                "illustrative_outcome_up",
                "selected_scenario_case",
                "generation_method",
            ],
        ),
        "scenario_metrics.json": json.dumps(
            metrics, ensure_ascii=False, indent=2, sort_keys=True
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
        help="Fail when committed scenario artifacts are missing, stale, or legacy-named.",
    )
    args = parser.parse_args()
    expected = build_artifacts()
    legacy = sorted(name for name in LEGACY_FILENAMES if (OUTPUT_ROOT / name).exists())
    if args.check:
        stale = [
            name
            for name, content in expected.items()
            if not (OUTPUT_ROOT / name).exists()
            or (OUTPUT_ROOT / name).read_text(encoding="utf-8") != content
        ]
        if legacy:
            stale.extend(legacy)
        if stale:
            raise SystemExit(
                f"Scenario artifacts are missing, stale, or legacy-named: {', '.join(stale)}"
            )
        print(f"Deterministic synthetic scenario verified: {len(expected)} files")
        return

    if legacy:
        raise SystemExit(
            "Remove legacy artifact names before generation: " + ", ".join(legacy)
        )
    OUTPUT_ROOT.mkdir(parents=True, exist_ok=True)
    for name, content in expected.items():
        (OUTPUT_ROOT / name).write_text(content, encoding="utf-8")
    print(f"Generated {len(expected)} deterministic synthetic scenario artifacts in {OUTPUT_ROOT}")


if __name__ == "__main__":
    main()
