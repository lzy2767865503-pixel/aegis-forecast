#!/bin/zsh

set -eu

project_root="$(cd "$(dirname "$0")" && pwd)"
cd "$project_root"

if [[ ! -x .venv/bin/python || ! -f frontend/dist/index.html ]]; then
  ./scripts/setup.sh
fi

export PYTHONPATH="$project_root/backend:$project_root"
export AEGIS_ENABLE_SIMULATION_EXECUTION="${AEGIS_ENABLE_SIMULATION_EXECUTION:-0}"

echo "Aegis Forecast is starting in safe research mode."
echo "Real trading is permanently disabled."
open "http://127.0.0.1:8766" >/dev/null 2>&1 &
exec ./.venv/bin/python -m aegis_quant.cli serve --host 127.0.0.1 --port 8766
