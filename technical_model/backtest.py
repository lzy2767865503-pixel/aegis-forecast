from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Dict, Mapping, Optional, Sequence, Tuple

import numpy as np
import pandas as pd


@dataclass
class BacktestResult:
    predictions: pd.DataFrame
    latest: pd.DataFrame
    thresholds: pd.DataFrame
    metrics: Dict[str, object]
    regime_metrics: pd.DataFrame


def wilson_lower_bound(successes: float, total: int, z: float = 1.96) -> float:
    if total <= 0:
        return float("nan")
    probability = float(successes) / float(total)
    denominator = 1.0 + (z * z) / total
    center = probability + (z * z) / (2.0 * total)
    margin = z * math.sqrt(
        (probability * (1.0 - probability) + (z * z) / (4.0 * total)) / total
    )
    return (center - margin) / denominator


def _candidate_metrics(train: pd.DataFrame, threshold: float) -> Dict[str, float]:
    selected = train[
        train["base_candidate"]
        & train["market_trade_allowed"]
        & (train["technical_score"] >= float(threshold))
        & train["label_up"].notna()
    ]
    count = int(len(selected))
    if count == 0:
        return {
            "threshold": float(threshold),
            "signals": 0,
            "precision": float("nan"),
            "precision_lcb": float("nan"),
            "action_precision": float("nan"),
            "average_return": float("nan"),
        }
    hits = float(selected["label_up"].sum())
    return {
        "threshold": float(threshold),
        "signals": count,
        "precision": hits / count,
        "precision_lcb": wilson_lower_bound(hits, count),
        "action_precision": float(selected["label_action"].mean()),
        "average_return": float(selected["forward_return_net"].mean()),
    }


def choose_threshold(train: pd.DataFrame, validation: Mapping[str, object]) -> Tuple[float, pd.DataFrame]:
    def aggressive_cap(value: float) -> float:
        cap = validation.get("maximum_score_threshold")
        return min(float(value), float(cap)) if cap is not None else float(value)

    grid = [float(value) for value in validation["threshold_grid"]]
    table = pd.DataFrame([_candidate_metrics(train, threshold) for threshold in grid])
    minimum = int(validation["minimum_training_signals"])
    target = float(validation["target_precision"])
    qualifying = table[
        (table["signals"] >= minimum)
        & (table["precision"] >= target)
        & (table["average_return"] > 0)
    ]
    if not qualifying.empty:
        # Precision is the hard gate; among passing thresholds prefer coverage.
        chosen = qualifying.sort_values(["threshold", "signals"], ascending=[True, False]).iloc[0]
        return aggressive_cap(float(chosen["threshold"])), table

    usable = table[(table["signals"] >= minimum) & table["precision"].notna()].copy()
    if usable.empty:
        return aggressive_cap(float(validation.get("default_score_threshold", 76.0))), table
    usable["fallback_objective"] = (
        usable["precision_lcb"].fillna(0.0)
        + 0.25 * usable["precision"].fillna(0.0)
        + 2.0 * usable["average_return"].fillna(0.0).clip(lower=-0.05, upper=0.05)
    )
    chosen = usable.sort_values(["fallback_objective", "threshold"], ascending=[False, True]).iloc[0]
    return aggressive_cap(float(chosen["threshold"])), table


def _empirical_probability(
    train: pd.DataFrame,
    score: float,
    regime: str,
    label: str,
    minimum_neighbors: int,
) -> Tuple[float, int]:
    eligible = train[
        train["base_candidate"]
        & train["market_trade_allowed"]
        & train[label].notna()
    ]
    if eligible.empty:
        return 0.5, 0
    regime_rows = eligible[eligible["market_state"].eq(regime)]
    neighbors = regime_rows[(regime_rows["technical_score"] - score).abs() <= 5.0]
    if len(neighbors) < minimum_neighbors:
        neighbors = regime_rows[(regime_rows["technical_score"] - score).abs() <= 10.0]
    if len(neighbors) < minimum_neighbors:
        neighbors = eligible[(eligible["technical_score"] - score).abs() <= 10.0]
    if len(neighbors) < max(10, minimum_neighbors // 2):
        neighbors = eligible
    baseline = float(eligible[label].mean())
    count = int(len(neighbors))
    hits = float(neighbors[label].sum())
    prior_strength = 4.0
    probability = (hits + prior_strength * baseline) / (count + prior_strength)
    return float(probability), count


def _calibrate_rows(
    rows: pd.DataFrame,
    train: pd.DataFrame,
    minimum_neighbors: int,
) -> pd.DataFrame:
    calibrated = rows.copy()
    p_up = []
    p_action = []
    neighbor_counts = []
    for _, row in calibrated.iterrows():
        up, n_up = _empirical_probability(
            train=train,
            score=float(row["technical_score"]),
            regime=str(row["market_state"]),
            label="label_up",
            minimum_neighbors=minimum_neighbors,
        )
        action, _ = _empirical_probability(
            train=train,
            score=float(row["technical_score"]),
            regime=str(row["market_state"]),
            label="label_action",
            minimum_neighbors=minimum_neighbors,
        )
        p_up.append(up)
        p_action.append(action)
        neighbor_counts.append(n_up)
    calibrated["p_up"] = p_up
    calibrated["p_action"] = p_action
    calibrated["calibration_neighbors"] = neighbor_counts
    variance = calibrated["p_up"] * (1.0 - calibrated["p_up"]) / (
        calibrated["calibration_neighbors"].clip(lower=1) + 4.0
    )
    calibrated["p_safe"] = (calibrated["p_up"] - 0.5 * np.sqrt(variance)).clip(0.0, 1.0)
    calibrated["ranking_value"] = 0.55 * calibrated["p_safe"] + 0.30 * calibrated[
        "p_action"
    ] + 0.15 * (calibrated["technical_score"] / 100.0)
    return calibrated


def _select_up_to_n(
    calibrated: pd.DataFrame,
    threshold: float,
    gates: Mapping[str, object],
) -> pd.DataFrame:
    selected = calibrated[
        calibrated["base_candidate"]
        & calibrated["market_trade_allowed"]
        & (calibrated["technical_score"] >= float(threshold))
        & (calibrated["p_up"] >= float(gates["minimum_p_up"]))
        & (calibrated["p_action"] >= float(gates["minimum_p_action"]))
    ].copy()
    selected = selected.sort_values(
        ["ranking_value", "technical_score"], ascending=[False, False]
    ).head(int(gates["maximum_names"]))
    return selected


def _expected_calibration_error(frame: pd.DataFrame, bins: int = 5) -> float:
    if frame.empty:
        return float("nan")
    work = frame[["p_up", "label_up"]].dropna().copy()
    if len(work) < bins:
        return float("nan")
    try:
        work["bin"] = pd.qcut(work["p_up"], q=bins, duplicates="drop")
    except ValueError:
        return float("nan")
    total = len(work)
    error = 0.0
    for _, group in work.groupby("bin", observed=True):
        error += len(group) / total * abs(float(group["p_up"].mean()) - float(group["label_up"].mean()))
    return float(error)


def summarize_predictions(
    predictions: pd.DataFrame,
    scored_weekly: pd.DataFrame,
    threshold_history: pd.DataFrame,
) -> Tuple[Dict[str, object], pd.DataFrame]:
    signals = predictions[predictions["selected_signal"]].copy()
    evaluated = signals[signals["label_up"].notna()].copy()
    baseline_rows = scored_weekly[
        scored_weekly["tradable_universe"] & scored_weekly["label_up"].notna()
    ]
    baseline = float(baseline_rows["label_up"].mean()) if not baseline_rows.empty else float("nan")
    if evaluated.empty:
        metrics = {
            "signal_count": 0,
            "evaluated_signal_count": 0,
            "weeks_with_signals": 0,
            "precision_up": float("nan"),
            "precision_lcb_95": float("nan"),
            "precision_action": float("nan"),
            "baseline_up_rate": baseline,
            "lift_vs_baseline": float("nan"),
            "average_net_return": float("nan"),
            "median_net_return": float("nan"),
            "average_excess_return": float("nan"),
            "profit_factor": float("nan"),
            "signal_basket_max_drawdown": float("nan"),
            "brier_score": float("nan"),
            "ece_5bin": float("nan"),
        }
        return metrics, pd.DataFrame()

    hits = float(evaluated["label_up"].sum())
    positive = evaluated.loc[evaluated["forward_return_net"] > 0, "forward_return_net"].sum()
    negative = -evaluated.loc[evaluated["forward_return_net"] < 0, "forward_return_net"].sum()
    weekly_returns = evaluated.groupby("date")["forward_return_net"].mean().sort_index()
    equity = (1.0 + weekly_returns).cumprod()
    drawdown = equity / equity.cummax() - 1.0
    precision = hits / len(evaluated)
    metrics = {
        "signal_count": int(len(signals)),
        "evaluated_signal_count": int(len(evaluated)),
        "weeks_with_signals": int(evaluated["date"].nunique()),
        "average_names_per_signal_week": float(evaluated.groupby("date").size().mean()),
        "precision_up": precision,
        "precision_lcb_95": wilson_lower_bound(hits, len(evaluated)),
        "precision_action": float(evaluated["label_action"].mean()),
        "baseline_up_rate": baseline,
        "lift_vs_baseline": precision / baseline if baseline and not np.isnan(baseline) else float("nan"),
        "average_net_return": float(evaluated["forward_return_net"].mean()),
        "median_net_return": float(evaluated["forward_return_net"].median()),
        "average_excess_return": float(evaluated["relative_forward_return"].mean()),
        "profit_factor": float(positive / negative) if negative > 0 else float("inf"),
        "signal_basket_max_drawdown": float(drawdown.min()),
        "brier_score": float(np.mean((evaluated["p_up"] - evaluated["label_up"]) ** 2)),
        "ece_5bin": _expected_calibration_error(evaluated, 5),
        "average_threshold": float(threshold_history["threshold"].mean())
        if not threshold_history.empty
        else float("nan"),
    }
    regime_metrics = (
        evaluated.groupby("market_state")
        .agg(
            signals=("label_up", "size"),
            precision_up=("label_up", "mean"),
            precision_action=("label_action", "mean"),
            average_return=("forward_return_net", "mean"),
            average_excess=("relative_forward_return", "mean"),
        )
        .reset_index()
    )
    return metrics, regime_metrics


def run_walk_forward(scored: pd.DataFrame, config: Mapping[str, object]) -> BacktestResult:
    forecast = config["forecast"]
    validation = dict(config["validation"])
    validation["default_score_threshold"] = config["gates"]["default_score_threshold"]
    gates = config["gates"]
    holding_days = int(forecast["holding_days"])
    training_days = int(validation["training_days"])
    minimum_neighbors = int(validation["probability_minimum_neighbors"])

    weekly = scored[scored["is_week_end"]].copy().sort_values(["date", "code"])
    all_dates = sorted(scored["date"].dropna().unique())
    date_position = {pd.Timestamp(value): index for index, value in enumerate(all_dates)}
    weekly_dates = sorted(weekly["date"].dropna().unique())
    prediction_parts = []
    threshold_rows = []

    for raw_date in weekly_dates:
        signal_date = pd.Timestamp(raw_date)
        position = date_position.get(signal_date)
        if position is None or position < training_days + holding_days:
            continue
        cutoff_position = position - holding_days
        train_start_position = max(0, cutoff_position - training_days)
        train_start = pd.Timestamp(all_dates[train_start_position])
        train_cutoff = pd.Timestamp(all_dates[cutoff_position])
        train = weekly[
            weekly["date"].between(train_start, train_cutoff)
            & weekly["label_up"].notna()
        ].copy()
        if train.empty:
            continue
        threshold, threshold_table = choose_threshold(train, validation)
        current = weekly[weekly["date"].eq(signal_date)].copy()
        calibrated = _calibrate_rows(current, train, minimum_neighbors)
        selected_index = _select_up_to_n(calibrated, threshold, gates).index
        calibrated["selected_signal"] = calibrated.index.isin(selected_index)
        calibrated["walk_forward_threshold"] = threshold
        calibrated["train_start"] = train_start
        calibrated["train_cutoff"] = train_cutoff
        prediction_parts.append(calibrated)
        chosen_row = threshold_table[threshold_table["threshold"].eq(threshold)]
        chosen_metrics = chosen_row.iloc[0].to_dict() if not chosen_row.empty else {}
        threshold_rows.append(
            {
                "date": signal_date,
                "train_start": train_start,
                "train_cutoff": train_cutoff,
                "threshold": threshold,
                **{("training_" + key): value for key, value in chosen_metrics.items() if key != "threshold"},
            }
        )

    predictions = pd.concat(prediction_parts, ignore_index=True) if prediction_parts else pd.DataFrame()
    thresholds = pd.DataFrame(threshold_rows)
    metrics, regime_metrics = summarize_predictions(predictions, weekly, thresholds)

    latest_date = scored["date"].max()
    latest_rows = scored[scored["date"].eq(latest_date)].copy()
    if not predictions.empty:
        latest_known_position = date_position[pd.Timestamp(latest_date)] - holding_days
        latest_cutoff = pd.Timestamp(all_dates[max(0, latest_known_position)])
        latest_start = pd.Timestamp(all_dates[max(0, latest_known_position - training_days)])
        latest_train = weekly[
            weekly["date"].between(latest_start, latest_cutoff) & weekly["label_up"].notna()
        ]
        latest_threshold, _ = choose_threshold(latest_train, validation)
        latest = _calibrate_rows(latest_rows, latest_train, minimum_neighbors)
        selected_index = _select_up_to_n(latest, latest_threshold, gates).index
        latest["selected_signal"] = latest.index.isin(selected_index)
        latest["walk_forward_threshold"] = latest_threshold
    else:
        latest = latest_rows.copy()
        latest["p_up"] = np.nan
        latest["p_action"] = np.nan
        latest["p_safe"] = np.nan
        latest["ranking_value"] = latest["technical_score"] / 100.0
        latest["selected_signal"] = False
        latest["walk_forward_threshold"] = float(gates["default_score_threshold"])
    latest = latest.sort_values(["selected_signal", "ranking_value"], ascending=[False, False])
    return BacktestResult(
        predictions=predictions,
        latest=latest.reset_index(drop=True),
        thresholds=thresholds,
        metrics=metrics,
        regime_metrics=regime_metrics,
    )
