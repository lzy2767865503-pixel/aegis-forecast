# Same-byte two-round Windows QA

Product author: **LAI ZEYU（来泽宇）**. Visible
`PublisherDisplayName`: **LAI ZEYU**. Private development certificate subject:
**CN=A5F91D0A-30C6-48EE-944F-B767FA872BE8**, because an MSIX signer must match
the Partner Center technical manifest Publisher; this is not an author credit.

The protected Store workflow uses one self-hosted Windows x64 runner with an
active interactive desktop. It builds the frozen sidecar and one unsigned
Partner Center x64 MSIX, copies those exact bytes once, then signs only the QA
copy. It proves the full non-signature content tree is byte-identical and runs:

1. native QA round 1;
2. native QA round 2;
3. strict WACK round 1 (`reset` and `test`);
4. strict WACK round 2 (`reset` and `test`).

After the one initial QA copy/sign step, no round downloads, rebuilds, copies or
resigns it. Each stage compares its size/SHA-256 with `candidate.json`, rechecks
the unsigned original, and recomputes the common payload-tree hash. Release
metadata rejects any differing package or lineage hash.

Each native QA round must:

- fail closed if a same-identity package, same-named shell/sidecar process,
  unpackaged fallback LocalState, or exact trusted certificate already exists;
- verify the development certificate and manifest Publisher equal the hard-locked
  Partner Center technical Publisher, while `PublisherDisplayName` remains
  exactly `LAI ZEYU`;
- unpack and inspect manifest identity, `zh-cn`, legal files, exact config
  allowlist and absence of account/execution modules;
- run the dependency-boundary command with an independent temporary data root
  and prove it writes neither that root nor fallback LocalState;
- validate EXE Product/Company/Copyright and an InformationalVersion containing
  the source commit exactly once;
- install the exact package and wait for `runtime/ui_ready.json` only after both
  the WinUI shell and React UI validate health, status, signals, universe and
  data APIs;
- require a distinct 256-bit launch nonce, then match shell/sidecar names, PIDs
  and canonical executable paths to the package `InstallLocation` before
  treating either PID as owned;
- force-kill only the recorded shell PID and require only the recorded sidecar
  PID to exit through the parent-process watchdog;
- uninstall only the exact PackageFullName created by the round and prove no
  process, PFN/LocalState, fallback LocalState, or installed package remains.

Each WACK round has a separate evidence root, deletes any old round directory,
captures fresh PowerShell
and appcert console transcripts, hard-kills timed-out process trees, checks native
exits, rejects partial/skipped/not-run/warning results, requires every XML result
to be `PASS` under a nonempty requirement, rehashes the package afterward, and
fails if it leaves a runtime process, package, PFN data root, or exact new
`appcert_*` root installed. Cleanup is limited to path-and-creation-time-bound
PIDs, exact PackageFullNames/PFN/AppCert roots, and the exact certificate
thumbprint created for this run; preflight refuses matching preexisting state or
another running AppCert process on the dedicated runner. A fresh exact
`%WINDIR%\Temp\appcert_*` root is registered before its package manifest is
expected, so even an extraction failure cannot leak a partial test root.

After strict schema/canonical-content checks, the Store workflow retains only
the unsigned original plus checksum, lineage and ACL receipt beneath the
pre-provisioned local fixed-NTFS `AegisStoreHandoff` root. The root and run
directory allow only the runner account, SYSTEM and Administrators. It deletes the signed QA copy,
certificate and detailed evidence. Development QA and WACK still do not replace
Partner Center identity validation, Microsoft Store signing, or certification.
