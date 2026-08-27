# Reproducibility

## Portable source gate

```bash
corepack enable
corepack prepare pnpm@10.34.5 --activate
./scripts/setup.sh
./scripts/verify.sh
./scripts/verify.sh
```

The scenario generator derives deterministic values from public security symbols
with stable salted SHA-256 fractions. It does not read historical observations,
train a model, or produce a backtest.
`--check` compares five committed artifacts byte-for-byte. The official
Nasdaq-100 membership snapshot is dated **2026-08-26**; demo values are synthetic
and are not market observations.

## Windows candidate and native QA

The pipeline pins Python 3.13.14, Node 22.23.1, pnpm 10.34.5, .NET SDK 8.0.424,
PyInstaller and NuGet packages. Python build dependencies and all transitives
are hash-locked. One active-interactive self-hosted Windows job runs source/audit
gates, freezes the sidecar/legal bytes, restores NuGet in locked mode and builds
one technical-Publisher development MSIX from the reserved Identity Name. It
then runs native QA rounds 1 and 2 sequentially,
followed by strict WACK reset/test, without rebuilding, resigning, downloading,
or copying the candidate between rounds. Every stage verifies the same SHA-256
before and after use. The Store workflow uploads no package/private-evidence
artifact; after strict validation and cleanup it writes a fixed Job Summary and
may upload only four privacy-validated exact-candidate PNGs as a short-lived
operator transfer bundle, never as a claim of Store acceptance.

See `docs/windows/TWO_PASS_QA.md`. PyInstaller is not a cross-compiler; macOS
freezing cannot be reported as Windows/Store certification.

## Expected safety result

- health reports `WINDOWS_STORE_READ_ONLY`, offline synthetic mode and execution
  disabled;
- unauthenticated, cross-origin and invalid-host requests fail;
- all legacy transaction/execution/scheduler route families return HTTP 403;
- brokerage/account/history routes are absent;
- frozen/MSIX contents exclude financial/account/execution dependencies;
- UI identifies Simplified-Chinese-only, deterministic-synthetic limitations;
- marker-bound allowlisted deletion preserves unknown LocalState siblings;
- runtime scenario metrics exactly equal a fresh calculation over all 300
  shipped illustrative rows.
