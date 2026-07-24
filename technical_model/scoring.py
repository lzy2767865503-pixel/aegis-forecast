from __future__ import annotations

from typing import Mapping, Sequence

import numpy as np
import pandas as pd


RANK_COLUMNS = [
    "dist_ma20",
    "ma5_over_ma20",
    "ma20_over_ma60",
    "ema20_slope10",
    "ret5",
    "ret10",
    "ret20",
    "macd_hist_atr",
    "rs1",
    "rs5",
    "rs10",
    "rs20",
    "obv_slope10",
    "up_down_volume_ratio10",
    "position20",
    "position60",
    "amount_ma20",
]


def _rank_by_date(panel: pd.DataFrame, columns: Sequence[str]) -> pd.DataFrame:
    result = panel.copy()
    for column in columns:
        result["rank_" + column] = result.groupby("date")[column].rank(
            pct=True, method="average"
        )
    result["rank_low_atr"] = result.groupby("date")["atr_pct"].rank(
        pct=True, method="average", ascending=False
    )
    result["rank_low_drawdown"] = result.groupby("date")["drawdown20"].rank(
        pct=True, method="average"
    )
    return result


def _bounded_fit(value: pd.Series, center: float, width: float) -> pd.Series:
    return (1.0 - (value - center).abs() / width).clip(lower=0.0, upper=1.0)


def score_panel(panel: pd.DataFrame, config: Mapping[str, object]) -> pd.DataFrame:
    scored = _rank_by_date(panel, RANK_COLUMNS)
    weights = config["factor_weights"]
    forecast = config["forecast"]
    gates = config["gates"]

    rsi_fit = _bounded_fit(scored["rsi14"], center=62.0, width=22.0)
    adx_fit = _bounded_fit(scored["adx14"], center=30.0, width=25.0)
    volume_fit = _bounded_fit(scored["volume_ratio20"], center=1.8, width=1.8)
    mfi_fit = _bounded_fit(scored["mfi14"], center=62.0, width=28.0)
    distance_fit = _bounded_fit(scored["dist_ema20_atr"], center=0.9, width=2.4)
    compression_fit = _bounded_fit(scored["vol_compression"], center=0.85, width=0.85)
    wick_quality = (1.0 - scored["upper_wick_share"].fillna(1.0)).clip(0.0, 1.0)

    scored["factor_trend"] = 100.0 * pd.concat(
        [
            scored["rank_dist_ma20"],
            scored["rank_ma5_over_ma20"],
            scored["rank_ma20_over_ma60"],
            scored["rank_ema20_slope10"],
            adx_fit,
            (scored["plus_di14"] > scored["minus_di14"]).astype(float),
        ],
        axis=1,
    ).mean(axis=1)
    scored["factor_momentum"] = 100.0 * pd.concat(
        [
            scored["rank_ret5"],
            scored["rank_ret10"],
            scored["rank_ret20"],
            scored["rank_macd_hist_atr"],
            rsi_fit,
            (scored["macd_hist_delta"] > 0).astype(float),
        ],
        axis=1,
    ).mean(axis=1)
    scored["factor_relative_strength"] = 100.0 * pd.concat(
        [
            scored["rank_rs1"],
            scored["rank_rs5"],
            scored["rank_rs10"],
            scored["rank_rs20"],
        ],
        axis=1,
    ).mean(axis=1)
    scored["factor_volume_price"] = 100.0 * pd.concat(
        [
            volume_fit,
            scored["rank_obv_slope10"],
            scored["rank_up_down_volume_ratio10"],
            scored["close_location"].clip(0.0, 1.0),
            wick_quality,
            mfi_fit,
        ],
        axis=1,
    ).mean(axis=1)
    scored["factor_structure"] = 100.0 * pd.concat(
        [
            scored["rank_position20"],
            scored["rank_position60"],
            distance_fit,
            compression_fit,
            (scored["close_breakout20"] >= 0).astype(float),
        ],
        axis=1,
    ).mean(axis=1)
    scored["factor_risk_quality"] = 100.0 * pd.concat(
        [
            scored["rank_low_atr"],
            scored["rank_low_drawdown"],
            scored["rank_amount_ma20"],
            (scored["atr_pct"] <= float(gates["maximum_atr_pct"])).astype(float),
        ],
        axis=1,
    ).mean(axis=1)

    scored["penalty"] = 0.0
    scored.loc[scored["rsi14"] > 78, "penalty"] += 8.0
    scored.loc[scored["dist_ema20_atr"] > 2.5, "penalty"] += 8.0
    scored.loc[
        (scored["volume_ratio20"] > 3.5) & (scored["upper_wick_share"] > 0.5),
        "penalty",
    ] += 6.0
    scored.loc[scored["three_day_return"] > 0.18, "penalty"] += 6.0
    scored.loc[(scored["gap"] > 0.03) & (scored["close_location"] < 0.4), "penalty"] += 5.0
    scored.loc[scored["is_limit_up"] | scored["is_limit_down"], "penalty"] += 10.0

    scored["technical_score"] = (
        scored["factor_trend"] * float(weights["trend"])
        + scored["factor_momentum"] * float(weights["momentum"])
        + scored["factor_relative_strength"] * float(weights["relative_strength"])
        + scored["factor_volume_price"] * float(weights["volume_price"])
        + scored["factor_structure"] * float(weights["structure"])
        + scored["factor_risk_quality"] * float(weights["risk_quality"])
        - scored["penalty"]
    ).clip(lower=0.0, upper=100.0)

    scored["confirm_trend"] = (
        (scored["close"] > scored["ema20"])
        & (scored["ema10"] > scored["ema20"])
        & (scored["ema20_slope10"] > 0)
    )
    scored["confirm_momentum"] = (
        (scored["ret5"] > 0)
        & (scored["macd_hist"] > 0)
        & scored["rsi14"].between(50, 75)
    )
    scored["confirm_relative_strength"] = (scored["rs5"] > 0) & (scored["rs10"] > 0)
    scored["confirm_volume_price"] = (
        scored["volume_ratio20"].between(1.1, float(gates["maximum_volume_ratio"]))
        & (scored["close_location"] >= 0.55)
    )
    scored["confirm_structure"] = (
        (scored["position20"] >= 0.65)
        & (scored["drawdown20"] > -0.12)
        & (scored["dist_ema20_atr"] <= 2.5)
    )
    scored["confirm_risk"] = (
        (scored["atr_pct"] <= float(gates["maximum_atr_pct"]))
        & (scored["amount_ma20"] >= float(forecast["minimum_average_amount_20"]))
        & (~scored["is_st"])
    )
    confirmation_columns = [
        "confirm_trend",
        "confirm_momentum",
        "confirm_relative_strength",
        "confirm_volume_price",
        "confirm_structure",
        "confirm_risk",
    ]
    scored["confirmation_count"] = scored[confirmation_columns].sum(axis=1)
    scored["archetype"] = np.select(
        [scored["pattern_breakout"], scored["pattern_pullback"]],
        ["放量突破", "回踩再启动"],
        default="趋势评分",
    )

    required_columns = [
        "ma120",
        "rsi14",
        "atr_pct",
        "technical_score",
        "amount_ma20",
        "market_state",
    ]
    scored["data_complete"] = scored[required_columns].notna().all(axis=1)
    scored["tradable_universe"] = (
        scored["data_complete"]
        & (~scored["is_st"])
        & (~scored["is_limit_up"])
        & (~scored["is_limit_down"])
        & (scored["close"] >= 2.0)
        & (scored["amount_ma20"] >= float(forecast["minimum_average_amount_20"]))
    )
    require_trend = bool(gates.get("require_trend_confirmation", True))
    require_relative_strength = bool(gates.get("require_relative_strength_confirmation", True))
    require_pattern = bool(gates.get("require_pattern_confirmation", True))
    trend_gate = scored["confirm_trend"] if require_trend else pd.Series(True, index=scored.index)
    relative_strength_gate = (
        scored["confirm_relative_strength"]
        if require_relative_strength
        else pd.Series(True, index=scored.index)
    )
    pattern_gate = (
        scored["pattern_breakout"] | scored["pattern_pullback"]
        if require_pattern
        else pd.Series(True, index=scored.index)
    )
    scored["base_candidate"] = (
        scored["tradable_universe"]
        & scored["rsi14"].between(float(gates["minimum_rsi"]), float(gates["maximum_rsi"]))
        & (scored["atr_pct"] <= float(gates["maximum_atr_pct"]))
        & (scored["volume_ratio20"] <= float(gates["maximum_volume_ratio"]))
        & (scored["confirmation_count"] >= int(gates["minimum_confirmations"]))
        & trend_gate
        & relative_strength_gate
        & pattern_gate
    )
    scored["market_trade_allowed"] = scored["market_state"].isin(["RISK_ON", "NEUTRAL"])
    scored["score_bucket"] = pd.cut(
        scored["technical_score"],
        bins=[-np.inf, 70, 78, 85, np.inf],
        labels=["Reject", "C", "B", "A"],
    ).astype(str)
    return scored.sort_values(["date", "technical_score"], ascending=[True, False]).reset_index(
        drop=True
    )


def current_ranking(scored: pd.DataFrame, maximum_names: int = 5) -> pd.DataFrame:
    latest_date = scored["date"].max()
    latest = scored[scored["date"].eq(latest_date)].copy()
    latest = latest.sort_values("technical_score", ascending=False)
    return latest.head(maximum_names).reset_index(drop=True)
