# Model card

## Intended use

Cross-sectional technical research and simulation-only decision support for a
Nasdaq-100 security snapshot over a five-trading-day forecast horizon.

## Inputs

- adjusted daily OHLCV and turnover;
- Nasdaq-100 benchmark history;
- current constituent metadata;
- no fundamental, news, alternative or private customer data.

## Factor families

Trend, momentum, relative strength, price-volume behavior, market structure and
volatility/risk quality. The weighted technical score is gated by market
regime, liquidity, probability calibration and minimum evidence.

## Evaluation

The research pipeline uses a rolling training window, a five-day label
isolation, next-session entry approximation and configurable round-trip
friction. Reported diagnostics include baseline rate, precision, a 95%
precision lower bound, net return, profit factor, maximum drawdown, Brier score
and expected calibration error.

## Promotion policy

The public demo intentionally fails the conservative evidence claim. A
challenger may only be compared offline and cannot promote itself. Live trading
is not an available deployment state.

## Limitations

- Technical factors can fail abruptly during gaps and regime changes.
- A fixed index snapshot becomes stale after reconstitution.
- Backtests are sensitive to survivorship, data quality, timing assumptions,
  transaction costs, slippage and capacity.
- Synthetic demo metrics demonstrate interfaces, not predictive performance.
- Probability estimates are conditional and never guarantees.
