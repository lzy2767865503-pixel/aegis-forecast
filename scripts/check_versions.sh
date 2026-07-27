#!/usr/bin/env bash

set -euo pipefail

python_command="${1:-${PYTHON:-python3}}"

if ! command -v "$python_command" >/dev/null 2>&1; then
  echo "Python 3.10 or newer is required (command: $python_command)." >&2
  exit 1
fi

if ! "$python_command" -c '
import sys
if sys.version_info < (3, 10):
    raise SystemExit(
        f"Python 3.10 or newer is required; found "
        f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}."
    )
'; then
  exit 1
fi

if ! command -v node >/dev/null 2>&1; then
  echo "Node.js 20 or newer is required. See .nvmrc for the tested version." >&2
  exit 1
fi

node -e '
const version = process.versions.node;
const major = Number(version.split(".")[0]);
if (!Number.isInteger(major) || major < 20) {
  console.error(`Node.js 20 or newer is required; found ${version}.`);
  process.exit(1);
}
'

if ! command -v pnpm >/dev/null 2>&1; then
  echo "pnpm 10 or newer is required. Run: corepack enable && corepack prepare pnpm@10.34.5 --activate" >&2
  exit 1
fi

pnpm_version="$(pnpm --version)"
pnpm_major="${pnpm_version%%.*}"
if [[ ! "$pnpm_major" =~ ^[0-9]+$ ]] || (( pnpm_major < 10 )); then
  echo "pnpm 10 or newer is required; found ${pnpm_version}." >&2
  exit 1
fi

echo "Runtime versions accepted: $("$python_command" --version 2>&1), Node $(node --version), pnpm ${pnpm_version}"
