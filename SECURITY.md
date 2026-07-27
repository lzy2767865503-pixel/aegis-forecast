# Security and privacy

## Supported scope

Aegis Forecast is a local research workstation. Real-money execution is
permanently rejected by the broker adapter. The optional Moomoo integration
accepts only the `SIMULATE` environment.

## Data handling

- Credentials stay inside Moomoo OpenD and are never accepted by this project.
- Runtime databases, logs, model caches, account snapshots, orders, positions,
  resumes, keys and environment files are excluded from version control.
- The bundled demo artifacts are deterministic synthetic data, not customer,
  broker or market-vendor records.
- The server binds to `127.0.0.1` by default and does not provide authentication
  for internet exposure.

## Reporting a vulnerability

Use GitHub's
[private vulnerability reporting form](https://github.com/lzy2767865503-pixel/aegis-forecast/security/advisories/new).
Do not include account numbers, credentials, private keys, customer information
or live trading data in a public issue.
