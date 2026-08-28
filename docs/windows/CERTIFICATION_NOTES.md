# Microsoft Store certification notes

Author credit: **LAI ZEYU（来泽宇）**. Partner Center publisher display
identity: **LAI ZEYU**.

## Reviewer access

No account, credential, brokerage installation or network connection is needed.

1. Launch **Quant Scenario Studio by LAI ZEYU**.
2. Read the prominent Simplified-Chinese deterministic-synthetic notice.
3. Use the dashboard, research detail, illustrative factors and generated-sample consistency views.
4. Open Privacy to inspect no-telemetry/no-account-connector and local deletion.
5. Open About to inspect author and packaged legal-file location.

The application UI is Simplified Chinese only. The constituent scope is the
Nasdaq-100 snapshot dated 2026-08-26; displayed numeric values are synthetic.

## Automated evidence

- all legacy transaction/execution/scheduler route families receive HTTP 403;
- account connector and financial-history routes do not exist (HTTP 404);
- unauthenticated, invalid-Host and cross-Origin requests are rejected;
- mutation without CSRF receives HTTP 403 and a body over 64 KiB receives 413;
- frozen Store sidecar excludes financial/account/execution modules;
- installed manifest and EXE VersionInfo validate identity and author separately;
- the shell validates real health/status/signals/universe/data APIs before
  WebView2 navigation; React independently loads the same core APIs before the
  DOM marker can exist;
- nonce-bound `ui_ready.json` records product, **LAI ZEYU（来泽宇）**,
  API/DOM fields, exact PIDs, installed executable paths, commit and verified
  MSIX SHA-256; PIDs are not owned until all fields validate;
- QA force-kills the exact shell PID, proves watchdog exit of the exact sidecar
  PID, then uninstalls the exact PackageFullName and checks PFN plus fallback data;
- the same Windows job builds one unsigned submission, signs only its payload-
  equivalent QA copy, and runs QA1, QA2, WACK1 and WACK2 sequentially with exact
  submission, QA-copy and payload-tree hashes.

## Package capability and legal boundary

The manifest requests only `runFullTrust`, needed by the packaged WinUI desktop
app and its local child process. It declares no internet, webcam, microphone,
location, contacts, documents or financial-transaction capability. The unpacked
MSIX must include root license, third-party notices and dependency licenses.

## External gates CI cannot satisfy

- Reconfirm reserved Store ID `9NWTH4KJX5GW` and hard-locked Identity Name
  `LAIZEYU.QuantScenarioStudiobyLAIZEYU`. The technical Publisher is hard-locked to this account's
  GUID-form CN. `PublisherDisplayName` remains `LAI ZEYU` exactly.
- Visually approve first-party icon/tile/splash artwork and complete keyboard,
  Narrator, high-contrast and 100/125/150% scaling checks.
- Publish the privacy URL and open it while signed out.
- Complete live IARC, markets, pricing, rights and financial-content questions.
- Upload only the exact reviewed candidate lineage. Store signing and Microsoft
  certification are separate from the ephemeral CI development signature/WACK.

The interactive WACK workflow retains the unsigned submission, checksum,
lineage and ACL receipt beneath a pre-provisioned local fixed-NTFS root limited
to the runner account, SYSTEM and Administrators. Separately, an owner-dispatched
exact protected-main hosted run may retain an unsigned Partner Center transfer
artifact for one day with four screenshots, SPDX SBOM and two-pass lineage. It
never includes the signed QA copy, certificate or private key and is not a
GitHub Release. Passing CI, hosted lifecycle QA or WACK does not guarantee
Microsoft Store certification. GitHub end-user distribution is a separately
trusted/timestamped portable ZIP and is not the Store candidate.
