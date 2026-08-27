# Windows packaging boundary

`aegis_backend.spec` creates an x64 PyInstaller **onedir** sidecar. It bundles
only the research runtime, deterministic demo artifacts and compiled frontend.
The Store candidate excludes brokerage SDKs, account connectors, transaction
modules, legacy execution modules, scheduler configuration and private
market-data pipelines.

The sidecar accepts only loopback binds. The WinUI shell supplies a fresh
session token and its `ApplicationData.Current.LocalFolder.Path` on every
launch. Store read-only policy is compiled into `runtime_policy.py`; neither an
environment variable nor a settings file can enable execution.

Build on Windows through `scripts/windows/build-backend.ps1`. PyInstaller is
not a cross-compiler, so a macOS output is not a Windows validation artifact.

`scripts/windows/build-msix.ps1` produces the Partner Center submission once as
an unsigned MSIX, copies it, and signs only the temporary QA copy with the
ephemeral technical-Publisher certificate. The workflow requires byte equality
for every non-signature MSIX entry and one canonical payload-tree hash across
the two packages. QA1, QA2, WACK1 and WACK2 use the same signed QA bytes. Only
the unsigned original/checksum/non-secret lineage/ACL receipt may enter the
pre-provisioned local fixed-NTFS exact-ACL handoff; no Store package may be
uploaded to GitHub.
