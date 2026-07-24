# Architecture

## Design posture

Aegis Forecast is a modular monolith: one local HTTP process coordinates
research artifacts, read-only monitoring, audit state and an optional
simulation-only broker adapter. This keeps failure modes inspectable while the
system is still a research product.

## Runtime layers

1. **Universe** - loads the committed Nasdaq-100 security snapshot and can
   refresh it from the configured official endpoint.
2. **Data** - selects private model artifacts when the operator points to them;
   otherwise uses deterministic synthetic demo artifacts.
3. **Research** - engineers six technical factor families and produces
   probability-calibrated rankings using walk-forward evidence.
4. **Decision support** - derives entry triggers, pullback bands, ATR
   invalidation, staged take-profits, trailing stops and time exits.
5. **Broker boundary** - lists simulation funds, positions and orders through
   Moomoo OpenD only when installed. It rejects non-`SIMULATE` environments
   before broker access.
6. **Operations** - persists an autonomy heartbeat, profit snapshots and a
   SHA-256 event chain in a local SQLite database.
7. **Presentation** - serves a compiled React/Vite console from the same
   localhost origin.

## Safety invariants

- Real-money order routing has no implementation.
- The server binds to `127.0.0.1` unless an operator changes it.
- Automated simulation execution is opt-in through
  `AEGIS_ENABLE_SIMULATION_EXECUTION=1`.
- Credentials remain inside the vendor gateway.
- Symbol allowlisting happens before the adapter opens a trading context.
- Runtime state and broker-derived data are excluded from the repository.

## Artifact selection

At startup, the service resolves model artifacts in this order:

1. `AEGIS_MODEL_ROOT`, when explicitly configured;
2. private runtime artifacts under `storage/models/nasdaq100`;
3. bundled deterministic artifacts under `demo_data`.

The API exposes `dataMode` so the frontend and tests can distinguish demo from
private research artifacts.

## Persistence

SQLite uses WAL mode for local operational records. The P&L ledger stores
timestamped total-equity snapshots and derives daily, weekly, monthly and
annual profit from the first and latest equity observations in each US trading
day. Deposits and withdrawals require separate cash-flow adjustment before
these values can be interpreted as investment performance.
