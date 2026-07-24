# Privacy boundary

The public repository contains source code, policy configuration and synthetic
demo fixtures only.

Excluded by policy and `.gitignore`:

- names, phone numbers, email addresses and resumes;
- account identifiers, positions, orders, fills and profit history;
- SQLite databases, WAL files, caches and logs;
- `.env` files, API tokens, passwords, private keys and certificates;
- machine-specific launch agents, absolute local paths and deployment state;
- broker-derived historical market data and screenshots.

Before release, tracked files are scanned for private paths, account suffixes,
email addresses, key formats and common secret prefixes. GitHub history is also
reviewed because deleting a secret from the latest commit does not remove it
from earlier commits.
