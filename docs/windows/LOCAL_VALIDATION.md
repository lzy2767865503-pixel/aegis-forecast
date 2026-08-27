# Local validation record — 2026-08-27

Product: **Quant Scenario Studio by LAI ZEYU**

Author/release owner: **LAI ZEYU（来泽宇）**
Partner Center technical Publisher hard-lock:
**CN=A5F91D0A-30C6-48EE-944F-B767FA872BE8**

This record distinguishes portable macOS checks from Windows-native gates. It
is not Microsoft Store certification.

## Portable verification rounds

After the final source/document edits, `./scripts/verify.sh` is run twice
consecutively without source changes between rounds. Each round must pass:

| Gate | Round A | Round B |
|---|---:|---:|
| deterministic synthetic scenario (5 files) | PASS | PASS |
| Python/security/integrity tests | 25/25 | 25/25 |
| React production build (1,590 modules) | PASS | PASS |
| authenticated health/status/signals/data bootstrap | PASS | PASS |
| unauthenticated API returns 401 | PASS | PASS |
| generic transaction route returns 403 | PASS | PASS |

Additional portable evidence:

- exact author, publisher, signer, language and seven-keyword gate;
- privacy/secret scan over candidate files;
- all 300 illustrative rows recompute exactly to `scenario_metrics.json`;
- legacy prediction/learning routes return 404 and transaction families return 403;
- marker-bound deletion preserves unknown siblings and refuses an unbound root;
- `actionlint` parses both Windows workflows, including the custom interactive-runner label;
- PowerShell AST parser accepts every Windows script;
- Python compilation and React production build pass.

## Windows-native status

Pending until this exact source revision runs on the active-interactive
self-hosted Windows runner (the Windows
XAML compiler, packaged-process paths, Add/Remove-AppxPackage and WACK cannot be
executed on macOS):

- runner prerequisite: current Windows 11 x64, Windows SDK/App Certification Kit,
  WebView2 Runtime, an elevated administrator token, an active non-session-0
  Explorer desktop, a protected exact AppCert file-version variable, and exact labels
  `self-hosted`, `windows`, `x64`, `wack-interactive`;

- pinned x64 PyInstaller/WinUI/MSIX build with locked NuGet restore and legal files;
- one unsigned Partner Center MSIX built from the reserved Identity Name, copied
  once, with only the QA copy signed by the ephemeral technical Publisher;
- full non-signature payload-tree equivalence between submission and QA copy;
- sequential QA1, QA2, WACK1 and WACK2 before/after hashes over unchanged QA bytes;
- real health/core-data API-backed DOM marker and exact installed executable paths;
- force-killed shell followed by parent-watchdog sidecar exit;
- exact PackageFullName uninstall and absent PFN/fallback LocalState;
- stale-free WACK XML/transcripts with hard native exits, `PARTIAL_RUN=FALSE`,
  exactly one requirements root, at least one test per requirement, and one
  direct `PASS` result for every reported test;
- final keyboard/Narrator/high-contrast/scaling/manual visual review;
- Partner Center identity, privacy URL, submission and Microsoft certification.

The Store workflow can retain the verified unsigned handoff only beneath a
pre-provisioned local fixed-NTFS root with the exact restricted ACL; it cannot
submit to Partner Center or claim certification, and it uploads no Store MSIX
to GitHub. A separate protected GitHub workflow
publishes only a trusted, timestamped LAI ZEYU/来泽宇 portable ZIP after two
same-byte lifecycle rounds; it never publishes the technical-identity Store MSIX.
