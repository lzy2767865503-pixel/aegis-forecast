# Reproducibility

## Clean-room verification

```bash
git clone https://github.com/lzy2767865503-pixel/aegis-forecast.git
cd aegis-forecast
corepack enable
corepack prepare pnpm@10.34.5 --activate
./scripts/setup.sh
./scripts/verify.sh
```

The demo generator uses SHA-256-derived stable values from public symbol
strings. `--check` compares every committed artifact byte-for-byte with newly
generated output.

Python runtime and optional Moomoo dependencies are fully pinned in
`requirements.lock.txt` and `requirements-moomoo.lock.txt`. The frontend uses a
frozen pnpm lockfile. `.python-version`, `.nvmrc` and the `packageManager` field
record the reference toolchain.

## Supported environments

CI verifies Python 3.10 and 3.12 on Ubuntu through the same `scripts/setup.sh`
clean-room path used by a new clone, with Node.js 22.23.1 and pnpm 10.34.5. The
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
