from __future__ import annotations

import argparse
import json

from .audit import AuditLedger
from .integrity import ScenarioIntegrityRegistry
from .nasdaq100_universe import load_universe_config, sync_universe_config
from .paths import ensure_directories
from .server import serve


def main() -> None:
    parser = argparse.ArgumentParser(description="Aegis Forecast command line")
    subparsers = parser.add_subparsers(dest="command", required=True)
    bootstrap = subparsers.add_parser("bootstrap")
    bootstrap.add_argument("--refresh-universe", action="store_true")
    run = subparsers.add_parser("serve")
    run.add_argument("--host", default="127.0.0.1")
    run.add_argument("--port", type=int, default=8766)
    run.add_argument("--open", action="store_true")
    subparsers.add_parser("verify-audit")
    subparsers.add_parser("integrity-check")
    args = parser.parse_args()

    ensure_directories()
    AuditLedger()
    registry = ScenarioIntegrityRegistry()

    if args.command == "bootstrap":
        current = load_universe_config()
        if args.refresh_universe:
            current = sync_universe_config()
        print(json.dumps({"ok": True, "universe": current}, ensure_ascii=False, indent=2))
    elif args.command == "serve":
        serve(args.host, args.port, args.open)
    elif args.command == "verify-audit":
        print(json.dumps(AuditLedger().verify(), ensure_ascii=False, indent=2))
    elif args.command == "integrity-check":
        print(json.dumps(registry.run_cycle(), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
