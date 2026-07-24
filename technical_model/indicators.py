from __future__ import annotations

from typing import Iterable

import numpy as np
import pandas as pd


EPSILON = 1e-12


def ema(series: pd.Series, span: int) -> pd.Series:
    return series.ewm(span=span, adjust=False, min_periods=span).mean()


def rsi(series: pd.Series, period: int = 14) -> pd.Series:
    delta = series.diff()
    gains = delta.clip(lower=0)
    losses = -delta.clip(upper=0)
    avg_gain = gains.ewm(alpha=1.0 / period, adjust=False, min_periods=period).mean()
    avg_loss = losses.ewm(alpha=1.0 / period, adjust=False, min_periods=period).mean()
    rs = avg_gain / avg_loss.replace(0, np.nan)
    values = 100.0 - (100.0 / (1.0 + rs))
    return values.where(avg_loss > EPSILON, 100.0)


def true_range(frame: pd.DataFrame) -> pd.Series:
    previous_close = frame["close"].shift(1)
    components = pd.concat(
        [
            frame["high"] - frame["low"],
            (frame["high"] - previous_close).abs(),
            (frame["low"] - previous_close).abs(),
        ],
        axis=1,
    )
    return components.max(axis=1)


def atr(frame: pd.DataFrame, period: int = 14) -> pd.Series:
    return true_range(frame).ewm(alpha=1.0 / period, adjust=False, min_periods=period).mean()


def adx(frame: pd.DataFrame, period: int = 14) -> pd.DataFrame:
    up_move = frame["high"].diff()
    down_move = -frame["low"].diff()
    plus_dm = pd.Series(
        np.where((up_move > down_move) & (up_move > 0), up_move, 0.0), index=frame.index
    )
    minus_dm = pd.Series(
        np.where((down_move > up_move) & (down_move > 0), down_move, 0.0), index=frame.index
    )
    tr_smoothed = true_range(frame).ewm(
        alpha=1.0 / period, adjust=False, min_periods=period
    ).mean()
    plus_di = 100.0 * plus_dm.ewm(
        alpha=1.0 / period, adjust=False, min_periods=period
    ).mean() / tr_smoothed.replace(0, np.nan)
    minus_di = 100.0 * minus_dm.ewm(
        alpha=1.0 / period, adjust=False, min_periods=period
    ).mean() / tr_smoothed.replace(0, np.nan)
    dx = 100.0 * (plus_di - minus_di).abs() / (plus_di + minus_di).replace(0, np.nan)
    adx_value = dx.ewm(alpha=1.0 / period, adjust=False, min_periods=period).mean()
    return pd.DataFrame({"adx14": adx_value, "plus_di14": plus_di, "minus_di14": minus_di})


def obv(frame: pd.DataFrame) -> pd.Series:
    direction = np.sign(frame["close"].diff()).fillna(0.0)
    return (direction * frame["volume"]).cumsum()


def money_flow_index(frame: pd.DataFrame, period: int = 14) -> pd.Series:
    typical = (frame["high"] + frame["low"] + frame["close"]) / 3.0
    raw_flow = typical * frame["volume"]
    direction = typical.diff()
    positive = raw_flow.where(direction > 0, 0.0).rolling(period, min_periods=period).sum()
    negative = raw_flow.where(direction < 0, 0.0).rolling(period, min_periods=period).sum()
    ratio = positive / negative.replace(0, np.nan)
    values = 100.0 - (100.0 / (1.0 + ratio))
    return values.where(negative > EPSILON, 100.0)


def rolling_slope(series: pd.Series, window: int) -> pd.Series:
    x = np.arange(window, dtype=float)
    x_centered = x - x.mean()
    denominator = float(np.sum(x_centered**2))

    def _slope(values: np.ndarray) -> float:
        if np.isnan(values).any():
            return np.nan
        centered = values - values.mean()
        return float(np.sum(x_centered * centered) / denominator)

    return series.rolling(window, min_periods=window).apply(_slope, raw=True)


def percentile_rank(frame: pd.DataFrame, columns: Iterable[str]) -> pd.DataFrame:
    result = frame.copy()
    for column in columns:
        result[column + "_pct_rank"] = result.groupby("date")[column].rank(
            pct=True, method="average"
        )
    return result


def consecutive_true(values: pd.Series, window: int) -> pd.Series:
    return values.astype(float).rolling(window, min_periods=window).sum().eq(window)
