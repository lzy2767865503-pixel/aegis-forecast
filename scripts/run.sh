#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"

runtime_python="${PYTHON:-python3}"
if [[ -x .venv/bin/python ]]; then
  runtime_python="./.venv/bin/python"
fi
./scripts/check_versions.sh "$runtime_python"

if [[ ! -x .venv/bin/python || ! -f frontend/dist/index.html ]]; then
  ./scripts/setup.sh
fi

export PYTHONPATH="$project_root/backend:$project_root"
export AEGIS_ENABLE_SIMULATION_EXECUTION="${AEGIS_ENABLE_SIMULATION_EXECUTION:-0}"

exec ./.venv/bin/python -m aegis_quant.cli serve --host 127.0.0.1 --port "${AEGIS_PORT:-8766}"
