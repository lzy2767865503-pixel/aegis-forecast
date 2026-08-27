# Privacy boundary

The repository contains source, policy configuration and synthetic demo
fixtures only. It must not contain personal, brokerage or credential material.

Excluded by policy and `.gitignore`:

- names, phone numbers, email addresses and resumes;
- account identifiers, positions, orders, fills and profit history;
- SQLite databases, WAL files, caches and logs;
- `.env` files, API tokens, passwords, private keys and certificates;
- machine-specific absolute paths and deployment state;
- broker-derived market data and screenshots.

The Store package has no broker/account connector. Experimental non-Store
source modules are excluded from PyInstaller and do not change this boundary.

Tracked files and reachable Git history are scanned for common private paths,
key formats and secret prefixes. This scan is a release gate, not a substitute
for rotating any credential that has ever been exposed.

The user-facing Windows Store policy is
[docs/windows/PRIVACY_POLICY.md](windows/PRIVACY_POLICY.md).
