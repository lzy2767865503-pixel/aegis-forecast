#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"

python_command="${PYTHON:-python3}"
if ! command -v "$python_command" >/dev/null 2>&1; then
  echo "Python 3.10 or newer is required." >&2
  exit 1
fi

if [[ ! -x .venv/bin/python ]]; then
  "$python_command" -m venv .venv
fi

./.venv/bin/python -m pip install --upgrade pip
if [[ "${1:-}" == "--with-moomoo" ]]; then
  ./.venv/bin/python -m pip install -r requirements-moomoo.txt
else
  ./.venv/bin/python -m pip install -r requirements.txt
fi

if ! command -v pnpm >/dev/null 2>&1; then
  echo "pnpm 10 or newer is required to build the dashboard." >&2
  exit 1
fi

pnpm --dir frontend install --frozen-lockfile
pnpm --dir frontend build
PYTHONPATH=backend:. ./.venv/bin/python scripts/generate_demo_data.py

echo "Setup complete. Run ./scripts/run.sh and open http://127.0.0.1:8766"
