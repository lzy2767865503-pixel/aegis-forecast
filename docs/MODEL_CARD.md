# Deterministic scenario card

## Intended use

Quant Scenario Studio is an offline education interface for exploring a fixed
Nasdaq-100 constituent snapshot and a deterministic synthetic scenario. It is
not a trained model, market-data product, backtest, or prediction service.

## Inputs

- Nasdaq-100 constituent metadata labeled **2026-08-26**;
- public security codes and names;
- stable salted SHA-256 fractions generated locally;
- no historical prices, OHLCV, news, fundamentals, account, customer, or broker data.

## Generation

The generator maps each security code to illustrative reference values, six
illustrative factor dimensions, rule scores, and neutral sensitivity levels.
It also creates 300 independent illustrative outcome rows. The same inputs and
generator version always produce byte-identical files.

None of these values were fitted to observed outcomes. Terms such as “score,”
“frequency,” and “Brier” describe only the internally generated rows.

## Runtime metrics

The API recalculates sample count, selected-row count, mean generated score,
generated outcome frequencies, an illustrative Brier consistency value, and
bucket gaps from every shipped row. It then requires exact equality with
`demo_data/scenario_metrics.json`. Tests repeat the same comparison.

## Product boundary

- no training, challenger, promotion, drift, or automatic model replacement;
- no historical or out-of-sample accuracy statement;
- no trading, account connection, transaction, or personalized instruction;
- no inference from the generated values to real market behavior.

## Limitations

- A fixed constituent snapshot becomes stale after index changes.
- Stable hashes are useful for reproducible UI examples, not market modeling.
- Generated frequencies and diagnostics have no investment or forecasting meaning.
- The app is Simplified-Chinese-only in Store v1.
