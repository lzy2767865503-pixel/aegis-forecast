from __future__ import annotations

from typing import Dict, Mapping, Tuple

import numpy as np
import pandas as pd

from .indicators import adx, atr, ema, money_flow_index, obv, rolling_slope, rsi


def _limit_percentage(code: str, name: str) -> float:
    if str(code).startswith("US."):
        return 1000.0
    upper_name = str(name).upper()
    if str(code).startswith(("300", "301", "688")):
        return 20.0
    if str(code).startswith(("4", "8")):
        return 30.0
    return 10.0


def _future_min(series: pd.Series, horizon: int) -> pd.Series:
    shifted = [series.shift(-step) for step in range(1, horizon + 1)]
    return pd.concat(shifted, axis=1).min(axis=1)


def prepare_single_history(
    raw: pd.DataFrame,
    holding_days: int,
    round_trip_cost_bps: float,
) -> pd.DataFrame:
    frame = raw.copy().sort_values("date").reset_index(drop=True)
    code = str(frame["code"].iloc[-1])
    name = str(frame["name"].iloc[-1])

    for window in (5, 10, 20, 60, 120):
        frame["ma%d" % window] = frame["close"].rolling(window, min_periods=window).mean()
    frame["ema10"] = ema(frame["close"], 10)
    frame["ema20"] = ema(frame["close"], 20)
    frame["ema60"] = ema(frame["close"], 60)
    frame["ema120"] = ema(frame["close"], 120)

    frame["rsi14"] = rsi(frame["close"], 14)
    frame["atr14"] = atr(frame, 14)
    frame["atr_pct"] = frame["atr14"] / frame["close"].replace(0, np.nan)
    directional = adx(frame, 14)
    frame = pd.concat([frame, directional], axis=1)

    ema12 = ema(frame["close"], 12)
    ema26 = ema(frame["close"], 26)
    frame["macd"] = ema12 - ema26
    frame["macd_signal"] = ema(frame["macd"], 9)
    frame["macd_hist"] = frame["macd"] - frame["macd_signal"]
    frame["macd_hist_atr"] = frame["macd_hist"] / frame["atr14"].replace(0, np.nan)
    frame["macd_hist_delta"] = frame["macd_hist"].diff()

    for window in (3, 5, 10, 20, 60):
        frame["ret%d" % window] = frame["close"].pct_change(window, fill_method=None)

    frame["ema20_slope10"] = rolling_slope(frame["ema20"], 10) / frame["close"].replace(
        0, np.nan
    )
    frame["ema60_slope10"] = rolling_slope(frame["ema60"], 10) / frame["close"].replace(
        0, np.nan
    )
    frame["dist_ema20_atr"] = (frame["close"] - frame["ema20"]) / frame["atr14"].replace(
        0, np.nan
    )
    frame["dist_ma20"] = frame["close"] / frame["ma20"] - 1.0
    frame["ma5_over_ma20"] = frame["ma5"] / frame["ma20"] - 1.0
    frame["ma20_over_ma60"] = frame["ma20"] / frame["ma60"] - 1.0

    frame["volume_ma20"] = frame["volume"].rolling(20, min_periods=20).mean()
    frame["volume_ratio20"] = frame["volume"] / frame["volume_ma20"].replace(0, np.nan)
    frame["amount_ma20"] = frame["amount"].rolling(20, min_periods=20).mean()
    frame["turnover_ma20"] = frame["turnover_pct"].rolling(20, min_periods=20).mean()
    frame["obv"] = obv(frame)
    frame["obv_slope10"] = rolling_slope(frame["obv"], 10) / frame["volume_ma20"].replace(
        0, np.nan
    )
    frame["mfi14"] = money_flow_index(frame, 14)

    up_volume = frame["volume"].where(frame["close"] > frame["close"].shift(1), 0.0)
    down_volume = frame["volume"].where(frame["close"] < frame["close"].shift(1), 0.0)
    frame["up_down_volume_ratio10"] = up_volume.rolling(10, min_periods=10).sum() / down_volume.rolling(
        10, min_periods=10
    ).sum().replace(0, np.nan)

    day_range = (frame["high"] - frame["low"]).replace(0, np.nan)
    frame["close_location"] = (frame["close"] - frame["low"]) / day_range
    frame["upper_wick_share"] = (
        frame["high"] - frame[["open", "close"]].max(axis=1)
    ) / day_range
    frame["lower_wick_share"] = (
        frame[["open", "close"]].min(axis=1) - frame["low"]
    ) / day_range

    high20_previous = frame["high"].shift(1).rolling(20, min_periods=20).max()
    close20_previous = frame["close"].shift(1).rolling(20, min_periods=20).max()
    high60 = frame["high"].rolling(60, min_periods=60).max()
    low20 = frame["low"].rolling(20, min_periods=20).min()
    low60 = frame["low"].rolling(60, min_periods=60).min()
    frame["breakout20"] = frame["close"] / high20_previous - 1.0
    frame["trigger_level"] = np.maximum(frame["high"], high20_previous)
    frame["close_breakout20"] = frame["close"] / close20_previous - 1.0
    frame["position20"] = (frame["close"] - low20) / (frame["high"].rolling(20).max() - low20).replace(
        0, np.nan
    )
    frame["position60"] = (frame["close"] - low60) / (high60 - low60).replace(0, np.nan)
    frame["drawdown20"] = frame["close"] / frame["close"].rolling(20).max() - 1.0
    frame["support_level"] = pd.concat([frame["ema10"], frame["ema20"]], axis=1).min(axis=1)
    frame["invalid_level"] = pd.concat(
        [frame["ema20"], frame["low"].rolling(10, min_periods=10).min()], axis=1
    ).min(axis=1)
    frame["volatility5"] = frame["close"].pct_change(fill_method=None).rolling(5).std()
    frame["volatility20"] = frame["close"].pct_change(fill_method=None).rolling(20).std()
    frame["vol_compression"] = frame["volatility5"] / frame["volatility20"].replace(0, np.nan)
    frame["gap"] = frame["open"] / frame["close"].shift(1) - 1.0
    frame["three_day_return"] = frame["close"].pct_change(3, fill_method=None)

    frame["pattern_breakout"] = (
        (frame["close_breakout20"] > 0)
        & (frame["ema20"] > frame["ema60"])
        & (frame["ema20_slope10"] > 0)
        & frame["volume_ratio20"].between(1.4, 3.0)
        & (frame["close_location"] >= 0.70)
        & frame["rsi14"].between(55, 75)
    )
    recent_pullback = (
        ((frame["low"] - frame["ema10"]).abs() <= 0.5 * frame["atr14"])
        | ((frame["low"] - frame["ema20"]).abs() <= 0.5 * frame["atr14"])
    ).rolling(5, min_periods=5).max().astype(bool)
    frame["pattern_pullback"] = (
        (frame["close"] > frame["ema60"])
        & recent_pullback
        & (frame["close"] > frame["ema10"])
        & (frame["volume_ratio20"] >= 1.1)
        & (frame["rsi14"] >= 50)
        & (frame["macd_hist_delta"] > 0)
    )

    frame["is_st"] = False if code.startswith("US.") else "ST" in name.upper()
    ordinary_limit = _limit_percentage(code, name)
    if frame["is_st"].iloc[0]:
        frame["limit_pct"] = np.where(frame["date"] >= pd.Timestamp("2026-07-06"), 10.0, 5.0)
    else:
        frame["limit_pct"] = ordinary_limit
    frame["is_limit_up"] = frame["pct_change"] >= (frame["limit_pct"] - 0.15)
    frame["is_limit_down"] = frame["pct_change"] <= (-frame["limit_pct"] + 0.15)

    entry_open = frame["open"].shift(-1)
    exit_close = frame["close"].shift(-holding_days)
    gross_return = exit_close / entry_open - 1.0
    cost = float(round_trip_cost_bps) / 10000.0
    frame["forward_return_net"] = gross_return - cost
    frame["forward_min_low"] = _future_min(frame["low"], holding_days)
    frame["forward_mae"] = frame["forward_min_low"] / entry_open - 1.0
    frame["label_up"] = (frame["forward_return_net"] > 0).astype(float)
    frame.loc[frame["forward_return_net"].isna(), "label_up"] = np.nan
    return frame


def _market_state(frame: pd.DataFrame) -> pd.Series:
    risk_on = (
        (frame["market_close"] > frame["market_ma20"])
        & (frame["market_ma20"] > frame["market_ma60"])
        & (frame["market_ema20_slope10"] > 0)
        & (frame["breadth_ma20"] >= 0.55)
    )
    panic = (
        (frame["market_rsi14"] <= 30)
        & (frame["market_ret1"] <= -0.02)
        & (frame["breadth_ma20"] < 0.35)
    )
    risk_off = (
        (frame["market_close"] < frame["market_ma20"])
        & (frame["market_ma20"] < frame["market_ma60"])
        & (frame["breadth_ma20"] < 0.35)
    )
    return pd.Series(
        np.select([panic, risk_off, risk_on], ["PANIC", "RISK_OFF", "RISK_ON"], default="NEUTRAL"),
        index=frame.index,
    )


def build_feature_panel(
    histories: Mapping[str, pd.DataFrame],
    benchmark_code: str,
    holding_days: int,
    round_trip_cost_bps: float,
) -> Tuple[pd.DataFrame, pd.DataFrame]:
    prepared: Dict[str, pd.DataFrame] = {}
    for code, raw in histories.items():
        if str(code).startswith("_"):
            continue
        prepared[str(code)] = prepare_single_history(
            raw=raw,
            holding_days=holding_days,
            round_trip_cost_bps=round_trip_cost_bps,
        )

    if benchmark_code not in prepared:
        raise ValueError("benchmark %s missing from prepared histories" % benchmark_code)
    market = prepared[benchmark_code].copy()
    market = market.rename(
        columns={
            "close": "market_close",
            "ma20": "market_ma20",
            "ma60": "market_ma60",
            "rsi14": "market_rsi14",
            "ema20_slope10": "market_ema20_slope10",
            "ret5": "market_ret5",
            "ret10": "market_ret10",
            "ret20": "market_ret20",
            "forward_return_net": "market_forward_return_net",
        }
    )
    market["market_ret1"] = market["market_close"].pct_change(fill_method=None)
    market_columns = [
        "date",
        "market_close",
        "market_ma20",
        "market_ma60",
        "market_rsi14",
        "market_ema20_slope10",
        "market_ret1",
        "market_ret5",
        "market_ret10",
        "market_ret20",
        "market_forward_return_net",
    ]
    market = market[market_columns]

    stock_frames = [frame for code, frame in prepared.items() if code != benchmark_code]
    panel = pd.concat(stock_frames, ignore_index=True)
    breadth = (
        panel.assign(
            above_ma20=panel["close"] > panel["ma20"],
            above_ma60=panel["close"] > panel["ma60"],
            trend_positive=(panel["ma20"] > panel["ma60"]),
        )
        .groupby("date")[["above_ma20", "above_ma60", "trend_positive"]]
        .mean()
        .rename(
            columns={
                "above_ma20": "breadth_ma20",
                "above_ma60": "breadth_ma60",
                "trend_positive": "breadth_trend",
            }
        )
        .reset_index()
    )
    market = market.merge(breadth, on="date", how="left")
    market["market_state"] = _market_state(market)
    panel = panel.merge(market, on="date", how="left", validate="many_to_one")
    panel["ret1"] = panel.groupby("code", sort=False)["close"].pct_change(fill_method=None)
    panel["rs1"] = panel["ret1"] - panel["market_ret1"]
    panel["rs5"] = panel["ret5"] - panel["market_ret5"]
    panel["rs10"] = panel["ret10"] - panel["market_ret10"]
    panel["rs20"] = panel["ret20"] - panel["market_ret20"]
    panel["relative_forward_return"] = (
        panel["forward_return_net"] - panel["market_forward_return_net"]
    )
    action_threshold = np.maximum(0.01, 0.5 * panel["atr_pct"])
    panel["label_action"] = (
        (panel["forward_return_net"] >= action_threshold)
        & (panel["relative_forward_return"] > 0)
        & (panel["forward_mae"] > -panel["atr_pct"])
    ).astype(float)
    panel.loc[panel["forward_return_net"].isna(), "label_action"] = np.nan

    week_key = panel["date"].dt.to_period("W-FRI")
    week_end = panel.groupby(["code", week_key])["date"].transform("max")
    panel["is_week_end"] = panel["date"].eq(week_end)
    return panel.sort_values(["date", "code"]).reset_index(drop=True), market
