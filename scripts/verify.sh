#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"

if [[ ! -x .venv/bin/python ]]; then
  echo "Run ./scripts/setup.sh first." >&2
  exit 1
fi

PYTHONPATH=backend:. ./.venv/bin/python scripts/generate_demo_data.py --check
./.venv/bin/python scripts/verify_attribution.py
./.venv/bin/python scripts/privacy_scan.py
test_data_root="$(mktemp -d -t quant-scenario-tests.XXXXXX)"
AEGIS_DATA_ROOT="$test_data_root" \
AEGIS_DATA_ROOT_BINDING="TEST:portable-unit-tests" \
PYTHONPATH=backend:. ./.venv/bin/python -m unittest discover -s tests -v
pnpm --dir frontend build

smoke_port="${AEGIS_SMOKE_PORT:-8877}"
smoke_log="$(mktemp -t aegis-forecast-smoke.XXXXXX)"
smoke_cookie="$(mktemp -t aegis-forecast-cookie.XXXXXX)"
smoke_index="$(mktemp -t aegis-forecast-index.XXXXXX)"
smoke_data_root="$(mktemp -d -t quant-scenario-smoke.XXXXXX)"
aegis_smoke_token="verification-session-token-000000000000000000000001"
AEGIS_ENABLE_SIMULATION_EXECUTION=0 \
AEGIS_SESSION_TOKEN="$aegis_smoke_token" \
AEGIS_DATA_ROOT="$smoke_data_root" \
AEGIS_DATA_ROOT_BINDING="TEST:portable-api-smoke" \
PYTHONPATH=backend:. \
  ./.venv/bin/python -m aegis_quant.cli serve --host 127.0.0.1 --port "$smoke_port" \
  >"$smoke_log" 2>&1 &
smoke_pid=$!

cleanup() {
  kill "$smoke_pid" >/dev/null 2>&1 || true
  wait "$smoke_pid" >/dev/null 2>&1 || true
  rm -f "$smoke_log" "$smoke_cookie" "$smoke_index"
  rm -rf "$test_data_root" "$smoke_data_root"
}
trap cleanup EXIT

for _ in {1..30}; do
  if curl -fsS -H "X-Aegis-Session: $aegis_smoke_token" "http://127.0.0.1:${smoke_port}/api/health" >/dev/null 2>&1; then
    break
  fi
  sleep 0.2
done

curl -fsS -H "X-Aegis-Session: $aegis_smoke_token" "http://127.0.0.1:${smoke_port}/api/health" \
  | ./.venv/bin/python -c "import json,sys; data=json.load(sys.stdin); assert data['ok'] and data['storeReadOnly'] and data['executionEnabled'] is False and data['mode'] == 'DETERMINISTIC_SYNTHETIC_SCENARIO'"
curl -fsS -H "X-Aegis-Session: $aegis_smoke_token" "http://127.0.0.1:${smoke_port}/api/signals?limit=8" \
  | ./.venv/bin/python -c "import json,sys; data=json.load(sys.stdin); assert len(data['items']) == 8"
curl -fsS -H "X-Aegis-Session: $aegis_smoke_token" "http://127.0.0.1:${smoke_port}/api/status" \
  | ./.venv/bin/python -c "import json,sys; data=json.load(sys.stdin); assert data['system']['dataMode'] == 'DETERMINISTIC_SYNTHETIC_SCENARIO'"
curl -fsS -H "X-Aegis-Session: $aegis_smoke_token" "http://127.0.0.1:${smoke_port}/api/data" \
  | ./.venv/bin/python -c "import json,sys; data=json.load(sys.stdin); assert data['coverage']['illustrativeOutcomeRows'] == 300"
curl -fsS -c "$smoke_cookie" -L "http://127.0.0.1:${smoke_port}/?session=$aegis_smoke_token" -o "$smoke_index"
grep -q "Quant Scenario Studio by LAI ZEYU" "$smoke_index"
csrf_token="$(sed -n 's/.*name="aegis-csrf-token" content="\([^"]*\)".*/\1/p' "$smoke_index" | head -n 1)"
test "${#csrf_token}" -ge 32
order_status="$(curl -sS -o /dev/null -w '%{http_code}' -b "$smoke_cookie" -H "Content-Type: application/json" -H "X-Aegis-CSRF: $csrf_token" --data '{}' "http://127.0.0.1:${smoke_port}/api/order/create")"
test "$order_status" = "403"

unauthorized_status="$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:${smoke_port}/api/health")"
test "$unauthorized_status" = "401"

echo "Verification passed: demo data, Python tests, frontend build, authenticated HTTP smoke and Store execution lock."
