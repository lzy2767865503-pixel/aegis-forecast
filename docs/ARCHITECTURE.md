# Windows Store architecture

## Components

1. **WinUI 3 shell** owns startup, shutdown, WebView2, package LocalState and the
   child-process lifecycle.
2. **PyInstaller onedir sidecar** contains the Python research runtime, compiled
   React UI and deterministic synthetic demo resources.
3. **Authenticated loopback API** serves UI and JSON from one origin. Each
   launch uses independent session and CSRF tokens.
4. **Scenario engine** loads the Nasdaq-100 constituent snapshot labeled
   **2026-08-26** and stable-hash illustrative generated samples. It does not
   load historical market observations or train a model.

The UI language is Simplified Chinese (`zh-CN`). The Store display name is
**Quant Scenario Studio by LAI ZEYU**, the exact bilingual author credit is
**LAI ZEYU（来泽宇）**. `PublisherDisplayName` is exactly **LAI ZEYU**.
The non-visible package `Identity Name` is hard-locked to the reserved Partner
Center value `LAIZEYU.QuantScenarioStudiobyLAIZEYU` for Store ID
`9NWTH4KJX5GW`, while its technical Publisher is hard-locked to
`CN=A5F91D0A-30C6-48EE-944F-B767FA872BE8`.

## Non-bypassable Store invariant

`backend/aegis_quant/runtime_policy.py` contains no environment/configuration
unlock and always denies execution. The HTTP handler rejects every legacy
transaction, execution and scheduler route family before route dispatch.

The Store package additionally excludes brokerage SDKs, account gateways,
financial-history modules, legacy execution modules and private market-data
pipelines. It contains neither execution configuration nor a financial-account
surface. The research service is fixed to bundled synthetic artifacts;
`AEGIS_MODEL_ROOT` is ignored.

## Process and DOM-ready lifecycle

```text
WinUI starts
  -> create 384-bit session token and package LocalState path
  -> start AegisBackend.exe on 127.0.0.1 with an ephemeral port
  -> wait for AEGIS_READY_URL
  -> independently validate health, status, signals, universe and data APIs
  -> set HttpOnly session cookie in WebView2
  -> navigate to the exact loopback origin
  -> wait until React has also loaded all core APIs successfully
  -> execute a DOM identity/read-only/privacy/API-readiness smoke
  -> write runtime/ui_ready.json only for an explicit QA request, bound to its
     256-bit nonce, exact PIDs, installed paths, source commit and package hash
Shell exits or is force-killed
  -> sidecar observes the exact parent PID and exits
```

The shell shows a visible failure instead of treating a process/window handle as
UI readiness. Native QA validates the marker, API fields, compiled EXE
VersionInfo, exact running executable paths beneath `InstallLocation`, and the
installed manifest. It force-kills the exact shell PID and requires the exact
sidecar PID to exit through its parent watchdog.

## Storage

Read-only resources resolve from the PyInstaller bundle. Mutable files resolve
from the absolute LocalState path plus `PFN:<PackageFamilyName>` binding supplied
by the shell. The backend verifies that path against `%LOCALAPPDATA%\Packages`,
writes an ownership marker, and refuses deletion without an exact marker match.
Deletion addresses only documented app-owned names and preserves unknown siblings.

No financial-account data is read or stored. The app has no remote endpoint,
telemetry, cloud account or background service. Its only socket is the
authenticated loopback session between the shell/UI and the sidecar.

## Build and release boundary

One owner-only manual job from exact `main` runs on a protected, elevated,
self-hosted Windows active interactive desktop. It injects the reserved
`Identity Name`, hard-locks the account technical
Publisher, and builds one private development MSIX exactly once. Native QA 1,
native QA 2 and approved-version bounded WACK then use that same byte sequence.
PIDs become cleanup targets only after process name, canonical path and creation
time validation. WACK also binds cleanup to exact PackageFullName/PFN/AppCert
roots captured during that run.

The Store verification workflow uploads no package or private evidence artifact.
It parses strict private schemas, regenerates a small canonical record, scans it
for embedded executable/archive/certificate/secret encodings, and writes a fixed
Job Summary. After private cleanup it may upload only four exact-candidate,
privacy-validated PNGs as a short-lived operator transfer bundle; that bundle is
not Microsoft Store acceptance evidence.

GitHub distribution is a separate portable ZIP, never the Store MSIX. A
protected non-Administrator build runner/account has no signing secrets and
freezes unsigned bytes into the ingress side of a same-host local fixed-NTFS
exact-ACL handoff. A different no-checkout
runner/account may sign them only through a pre-administered hash- and
Authenticode-bound orchestrator that consumes secrets from the environment and
attests that no credential entered argv. Before secret use it removes the build
SID and atomically moves the unchanged run into a signer/SYSTEM-only vault.
Repository CKA setup/cleanup scripts
are intentionally blocked. The signer receipt must prove certificate-store,
CNG-provider and private-key baselines are restored before signed bytes are
uploaded for two unchanged-byte hosted lifecycle passes.
The publisher accepts ownership only from one HTTP 201 response carrying the
immutable Release ID, node ID and creation time. A non-201, exception or malformed
response triggers no lookup/adoption/mutation. It then re-downloads the public
release and closes the loop over exact-ID asset hashes/signatures, tag
immutability and current remote-main ancestry.

Partner Center identity reservation, public privacy URL, final visual/accessibility
review and Microsoft Store signing remain release-time inputs. A development
signature or WACK PASS is not Store certification.
