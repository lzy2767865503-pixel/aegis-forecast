# Reproducibility

## Clean-room verification

```bash
git clone https://github.com/lzy2767865503-pixel/aegis-forecast.git
cd aegis-forecast
./scripts/setup.sh
./scripts/verify.sh
```

The demo generator uses SHA-256-derived stable values from public symbol
strings. `--check` compares every committed artifact byte-for-byte with newly
generated output.

## Supported environments

CI verifies Python 3.10 and 3.12 on Ubuntu with Node.js 22 and pnpm 10. The
macOS launcher uses the same Python service and compiled frontend.

## Expected result

- all unit tests pass;
- the tracked-file privacy scan passes;
- the frontend production bundle compiles;
- `/api/health` reports `executionEnabled: false`;
- `/api/signals?limit=8` returns eight deterministic rows;
- `/` serves the Aegis Forecast frontend.

Private Moomoo validation is deliberately outside public CI because it requires
a locally authenticated vendor gateway and a user-owned simulation account.
