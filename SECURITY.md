# Security and privacy

Quant Scenario Studio is authored by **LAI ZEYU（来泽宇）**. The
Microsoft Store candidate is a local, offline, read-only research application.

## Local HTTP boundary

- The sidecar binds only to loopback addresses.
- Each process uses fresh session and CSRF tokens. WebView2 receives the session
  as an HttpOnly, SameSite=Strict cookie.
- Host and Origin must match the active loopback port. State changes require the
  separate CSRF token.
- JSON bodies are capped at 64 KiB and must use `application/json`.
- CSP, frame denial, MIME-sniffing protection, no-referrer and restrictive
  permissions headers apply to API and static responses.
- Query strings containing a developer bootstrap token are never logged.
- WebView2 blocks non-loopback navigation, downloads, permissions, new windows,
  status bars, context menus and developer tools.

The service is not designed or supported for internet exposure.

## Store capability boundary

- REAL, LIVE and SIMULATE order/execution route families fail closed.
- The Store runtime has no brokerage SDK, financial-account connector,
  transaction history API, scheduler, legacy execution module or private
  market-data pipeline.
- The packaged import boundary is tested after freezing, and the unpacked MSIX
  is checked for forbidden modules and execution configuration.
- The app always uses deterministic synthetic artifacts dated 2026-08-26.
- No account, credential, trade-unlock value or financial snapshot is accepted.

Experimental connector source files, if retained for non-Store research, are
explicitly excluded from PyInstaller and are not a Store feature.

## Local data and supply chain

- Mutable state lives in package LocalState.
- In-app deletion removes only allowlisted directories (`models`, `experiments`,
  `runtime`, `settings`) and the exact `operational.db` SQLite files. Unknown
  siblings and sentinels are preserved by test.
- Secrets, logs, certificates, account data and personal documents are excluded
  from version control and checked by the privacy scanner.
- Runtime/build dependencies and transitives are version/hash locked. Store CI
  runs two nonce-distinct native QA rounds against the same private
  technical-identity MSIX SHA-256, then bounded complete WACK. Detailed evidence
  remains private and only a fixed Job Summary is emitted.
- Development certificates and identities are never distribution credentials.
  Partner Center identity and Microsoft Store signing remain separate gates.
- Public GitHub Windows bytes are a separate portable ZIP; every PE requires a
  trusted timestamped signer whose exact SimpleName is `LAI ZEYU` or `来泽宇`.

## Reporting

Use GitHub's
[private vulnerability reporting form](https://github.com/lzy2767865503-pixel/aegis-forecast/security/advisories/new).
Do not include credentials, private keys, personal records or financial data in
a public issue.
