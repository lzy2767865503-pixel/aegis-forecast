#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"

python_command="${PYTHON:-python3}"
if [[ -x .venv/bin/python ]]; then
  python_command="./.venv/bin/python"
fi
./scripts/check_versions.sh "$python_command"

if [[ ! -x .venv/bin/python ]]; then
  "$python_command" -m venv .venv
fi

./.venv/bin/python -m pip install --upgrade "pip==25.3"
if [[ "${1:-}" == "--with-moomoo" ]]; then
  ./.venv/bin/python -m pip install -r requirements-moomoo.lock.txt
else
  ./.venv/bin/python -m pip install -r requirements.lock.txt
fi

pnpm --dir frontend install --frozen-lockfile
pnpm --dir frontend build
PYTHONPATH=backend:. ./.venv/bin/python scripts/generate_demo_data.py

echo "Setup complete. Run ./scripts/run.sh and open http://127.0.0.1:8766"
