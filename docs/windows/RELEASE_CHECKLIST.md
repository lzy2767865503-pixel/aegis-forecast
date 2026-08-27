# Windows Store release checklist

Release owner/author: **LAI ZEYU（来泽宇）**. Partner Center publisher
display identity: **LAI ZEYU**.

## Identity and rights

- [x] Partner Center product is reserved as Store ID `9NWTH4KJX5GW` with
  production Identity Name `LAIZEYU.QuantScenarioStudiobyLAIZEYU`.
- [ ] Confirm repository variable `AEGIS_STORE_IDENTITY_NAME`, the literal
  manifest, and the workflow's hard-locked expected value all equal that exact
  Identity Name; any drift must fail before the self-hosted build.
- [ ] Set protected environment variable `AEGIS_APPROVED_WACK_FILE_VERSION` to
  the exact four-part file version of the currently approved AppCert executable;
  also set its exact lowercase SHA-256, Authenticode signer Subject/thumbprint,
  complete TEST count and TEST inventory SHA-256 in
  `AEGIS_APPROVED_WACK_SHA256`, `AEGIS_APPROVED_WACK_SIGNER_SUBJECT`,
  `AEGIS_APPROVED_WACK_SIGNER_THUMBPRINT`, `AEGIS_APPROVED_WACK_TEST_COUNT` and
  `AEGIS_APPROVED_WACK_TEST_INVENTORY_SHA256`. Missing/unapproved values block the run.
- [ ] Set protected `AEGIS_PRIVATE_STORE_HANDOFF_ROOT` to a pre-provisioned local
  fixed-NTFS directory named exactly `AegisStoreHandoff`, outside workspace/temp/
  OneDrive, with protected ACL FullControl only for the runner account, SYSTEM
  and local Administrators.
- [ ] Confirm technical `Identity Publisher` is exactly
  `CN=A5F91D0A-30C6-48EE-944F-B767FA872BE8` for this Partner Center account.
- [ ] Compare `PublisherDisplayName` byte-for-byte with Partner Center; expected
  verified value is `LAI ZEYU`, not the bilingual author credit.
- [ ] Verify **LAI ZEYU（来泽宇）** in About, EXE author/copyright,
  listing copy, privacy, README, notices and release evidence.
- [ ] Confirm rights to code, images, names and third-party components.
- [ ] Complete live IARC, category, markets, pricing and support declarations.

## Product truthfulness

- [ ] UI/listing state Simplified-Chinese-only support.
- [ ] Run the protected Windows Store workflow and download its four-file
  `aegis-store-listing-screenshot-<run-id>-<run-attempt>` artifact. Confirm the
  home/scenario/privacy/About PNGs are distinct, each is at least 1366x768, and
  each visibly matches the exact verified candidate.
  Never substitute `docs/assets/dashboard-demo.png`, a mock-up or a concept
  image for this gate. This short-lived Actions artifact is only a controlled
  screenshot transfer bundle: manually review and upload the same four PNGs in
  Partner Center. Its existence is not Microsoft validation, submission or acceptance.
- [ ] Every material view labels stable-hash deterministic synthetic/non-market data.
- [ ] Nasdaq scope says **2026-08-26 snapshot**, never “current constituents.”
- [ ] Neutral thresholds contain no buy/sell, position sizing, target/limit,
  legacy execution-module or personalized instruction.
- [ ] No brokerage SDK/account connector/financial-history UI or API is present.
- [ ] Keywords contain no more than seven entries.

## Privacy and security

- [ ] Publish and signed-out-test the privacy policy URL.
- [ ] Privacy/history scan, dependency audits and static checks pass.
- [ ] Host/Origin/session/CSRF/body-size/CSP tests pass.
- [ ] Marker-bound allowlisted LocalState deletion preserves unrelated sentinels.
- [ ] No secret, certificate/private-key container, account data or personal
  record appears in logs, screenshots, summaries or SBOM metadata.

## Package and quality

- [ ] NuGet restore uses tracked `packages.lock.json` in locked mode.
- [ ] Root/dependency legal files exist in the unpacked MSIX and About explains
  their location.
- [ ] Only the repository owner manually dispatches or reruns the Store job from
  the exact fetched `main` commit; no pull request, push event, or collaborator
  rerun reaches the self-hosted runner.
- [ ] One elevated, active-interactive self-hosted Windows job builds one unsigned
  Partner Center MSIX, makes one QA copy, and signs only that copy with the
  ephemeral technical-Publisher certificate. It verifies Microsoft-signed
  AppCert immediately before execution against all six protected version/hash/
  signer/test-inventory values and holds the exact executable against replacement.
- [ ] Full non-signature MSIX content and the canonical payload-tree hash are
  identical between the original unsigned submission and signed QA copy.
- [ ] The same job runs QA1, QA2, WACK1 and WACK2 sequentially on the unchanged
  signed QA-copy path, while every stage rebinds the unsigned-submission hash.
- [ ] Each round records before/after SHA, real health/core-data API success,
  DOM readiness, installed executable paths, exact PIDs, forced-shell watchdog
  exit, exact uninstall and absent PFN/fallback LocalState.
- [ ] Each WACK round removes stale evidence, captures fresh transcripts, hard-times out and
  kills its process tree, rejects partial/skipped/not-run/warning results,
  requires complete XML PASS and records the same before/after MSIX hash.
- [ ] Test keyboard, Narrator, high contrast, 100/125/150% scaling and offline
  launch on the final candidate.
- [ ] Keep the signed QA copy, certificate and detailed QA/WACK/SBOM evidence
  private and delete them after verification. Retain only the unsigned original,
  checksum and non-secret lineage JSON in the pre-provisioned local fixed-NTFS
  `AegisStoreHandoff` root whose ACL permits only the runner account, SYSTEM and
  Administrators; never upload any Store MSIX to GitHub.

## Publication state

- [ ] Follow `PARTNER_CENTER_RUNBOOK.md`, including OneDrive/Windows Backup stop.
- [ ] Push/tag only after review; no temporary development certificate is published.
- [ ] On the same protected runner, open the exact ACL-retained handoff, recheck
  SHA-256 and `NotSigned`, then
  upload only that reviewed unsigned package lineage to Partner Center. Microsoft
  Store applies the distribution signature after submission.
- [ ] Record upload, in-review, certified and publicly available as separate states.
- [ ] GitHub release is the separate portable ZIP, not the Store MSIX; every PE
  has a trusted timestamped `LAI ZEYU`/`来泽宇` signature and online-valid chain.
- [ ] Protected `windows-github-release` has the exact approval tag plus SSL.com
  eSigner username/password/TOTP secrets, but exposes them only to the separate
  no-checkout signer account. The checkout/build account has no signing secrets.
  Build and signer runner names/account SIDs are distinct and bind one physical
  host through the MachineGuid hash plus a local fixed-NTFS exact-ACL handoff.
- [ ] The handoff root has separate pre-provisioned `ingress` and `signer-vault`
  children. The non-Administrator build SID can write only ingress; before any
  secret use the signer removes that SID from every run object and atomically
  moves the unchanged run beneath the signer/SYSTEM-only vault. Administrators,
  broad principals, reparse ancestors and public unsigned artifacts are forbidden.
- [ ] `AEGIS_TRUSTED_SIGNER_ORCHESTRATOR_PATH`, its SHA-256 and Authenticode
  signer thumbprint identify one pre-administered script outside workspace/temp;
  credential transport is exactly `ENVIRONMENT_ONLY_NO_ARGV`. If the vendor path
  cannot satisfy that contract, public signing remains blocked.
- [ ] The cloud certificate SimpleName is exactly `LAI ZEYU` or `来泽宇`; no
  exportable key container is used.
- [ ] GitHub tag ruleset `21631608` remains active for `refs/tags/windows-v*`,
  has update and deletion rules, and has no bypass actors; the workflow verifies
  this both before signing and after public-release verification. Main ruleset
  `21633557` remains active with no bypass, deletion/non-fast-forward protection,
  required PRs and required review-thread resolution.
- [ ] The signer receipt proves exact run-created key `DeleteKey`, certificate
  store, CNG provider/private-key baselines, CKA state and temporary client are
  restored before signed bytes leave the signer. It binds the exact key container,
  unique name/provider, DeleteKey result, run/attempt, runner/MachineGuid hash,
  signer SID and locked orchestrator hash/AuthentiCode signer; a separate post-step
  recomputes all available baselines and exact-key absence. The no-checkout publisher
  establishes ownership only from immutable ID/node-ID/created-at fields in one
  successful HTTP 201 response; any ambiguous creation outcome is diagnostic-only.
- [ ] After publication, re-download the exact ZIP/checksum pair and reverify all
  PE signatures, signer and TSA EKUs/chains, immutable tag, and tag ancestry in
  current protected `main`. Any later failure must restore only the proven exact
  ID/node-ID/creation-time-bound Release to private draft and confirm that state.
