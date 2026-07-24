# Broker integration checklist

This repository is intentionally simulation-only. There is no live-trading
activation procedure.

Before enabling **automated simulation execution**, an operator should:

- [ ] install Moomoo OpenD from the official source;
- [ ] sign in locally and confirm a US `SIMULATE` account is available;
- [ ] keep OpenD bound to localhost;
- [ ] run the full repository verification gate;
- [ ] review the current symbol allowlist;
- [ ] confirm `config/t_trading.json` position, schedule and exit policies;
- [ ] test order rejection, duplicate prevention, restarts and stale data;
- [ ] monitor orders and fills in the broker application;
- [ ] keep `AEGIS_ENABLE_SIMULATION_EXECUTION=0` until ready.

The adapter rejects `REAL` and the application contains no live-money route.
