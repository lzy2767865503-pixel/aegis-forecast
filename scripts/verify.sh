#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"

if [[ ! -x .venv/bin/python ]]; then
  echo "Run ./scripts/setup.sh first." >&2
  exit 1
fi

PYTHONPATH=backend:. ./.venv/bin/python scripts/generate_demo_data.py --check
./.venv/bin/python scripts/privacy_scan.py
PYTHONPATH=backend:. ./.venv/bin/python -m unittest discover -s tests -v
pnpm --dir frontend build

smoke_port="${AEGIS_SMOKE_PORT:-8877}"
smoke_log="$(mktemp -t aegis-forecast-smoke.XXXXXX)"
AEGIS_ENABLE_SIMULATION_EXECUTION=0 \
PYTHONPATH=backend:. \
  ./.venv/bin/python -m aegis_quant.cli serve --host 127.0.0.1 --port "$smoke_port" \
  >"$smoke_log" 2>&1 &
smoke_pid=$!

cleanup() {
  kill "$smoke_pid" >/dev/null 2>&1 || true
  wait "$smoke_pid" >/dev/null 2>&1 || true
  rm -f "$smoke_log"
}
trap cleanup EXIT

for _ in {1..30}; do
  if curl -fsS "http://127.0.0.1:${smoke_port}/api/health" >/dev/null 2>&1; then
    break
  fi
  sleep 0.2
done

curl -fsS "http://127.0.0.1:${smoke_port}/api/health" \
  | ./.venv/bin/python -c "import json,sys; data=json.load(sys.stdin); assert data['ok'] and data['executionEnabled'] is False"
curl -fsS "http://127.0.0.1:${smoke_port}/api/signals?limit=8" \
  | ./.venv/bin/python -c "import json,sys; data=json.load(sys.stdin); assert len(data['items']) == 8"
curl -fsS "http://127.0.0.1:${smoke_port}/" \
  | grep -q "Aegis Forecast"

echo "Verification passed: demo data, Python tests, frontend build and HTTP smoke test."
