# Partner Center submission runbook

Release owner/author: **LAI ZEYU（来泽宇）**. Publisher display
identity expected from Partner Center: **LAI ZEYU**.

## Before packaging

1. Confirm Partner Center Store ID `9NWTH4KJX5GW`, Identity Name
   `LAIZEYU.QuantScenarioStudiobyLAIZEYU`, technical Publisher
   `CN=A5F91D0A-30C6-48EE-944F-B767FA872BE8`, and Publisher display name
   `LAI ZEYU` still match the reserved product.
2. Keep that exact manifest `Identity Name`/`Publisher`; keep `PublisherDisplayName`
   exactly `LAI ZEYU`. Do not put the bilingual author credit in that identity
   field. Microsoft documents these three values as Product identity values
   that must be copied into the package manifest:
   <https://learn.microsoft.com/en-us/windows/apps/publish/view-app-identity-details>.
3. Confirm only `zh-CN` is declared and the English listing begins with the
   Simplified-Chinese-only disclosure.
4. Set protected `AEGIS_APPROVED_WACK_FILE_VERSION`, `AEGIS_APPROVED_WACK_SHA256`,
   `AEGIS_APPROVED_WACK_SIGNER_SUBJECT`, `AEGIS_APPROVED_WACK_SIGNER_THUMBPRINT`,
   `AEGIS_APPROVED_WACK_TEST_COUNT` and `AEGIS_APPROVED_WACK_TEST_INVENTORY_SHA256`
   to one independently approved AppCert binary and complete TEST inventory.
   As repository owner, manually dispatch the
   single Windows job from exact `main` on an elevated active desktop; require
   QA1, QA2, WACK1 and WACK2 evidence showing the same signed QA-copy hash and
   the same original unsigned-submission/payload-tree lineage.
5. Open the privacy URL while signed out and compare every listing claim with
   the installed candidate.
6. Require the protected workflow's four-file Store screenshot transfer artifact. Its
   distinct home/scenario/privacy/About views are captured by the exact installed
   candidate only after nonce-bound DOM/API validation, each must be at least
   1366x768, and the PNGs are uploaded only after certificate and private
   build/WACK evidence cleanup. Review and manually upload those exact four PNGs
   in Partner Center; the Actions bundle itself is not Store submission,
   certification or acceptance. `docs/assets/dashboard-demo.png` is documentation
   artwork, not Store evidence.
7. Pre-provision a directory named exactly `AegisStoreHandoff` on a local fixed
   NTFS volume outside the checkout, runner temp and every OneDrive root. Disable
   inherited permissions and grant FullControl only to the exact Windows account
   running Actions, `SYSTEM`, and local `Administrators`; set its absolute path
   as protected environment variable `AEGIS_PRIVATE_STORE_HANDOFF_ROOT`. The
   workflow validates the volume, ancestors, owner and ACL before building and
   refuses to weaken or silently create this root.

## Disable automatic cloud backup for release evidence

The candidate, certificates and evidence must not enter OneDrive or Windows
Backup automatically:

1. Use a local build/evidence directory outside OneDrive-synced Desktop,
   Documents and Pictures.
2. In OneDrive **Settings > Sync and backup > Manage backup**, choose **Stop
   backup** for any release-evidence folder location. Confirm the folder no
   longer shows a OneDrive sync-status icon.
3. In Windows Backup settings, turn off app-folder backup for the temporary QA
   account. Do not enable settings sync for that account.
4. Search OneDrive for `*.pfx`, `*.cer`, `*.msix`, WACK reports and candidate
   manifests. Remove unintended cloud copies before continuing. Never upload a
   PFX. The Store-verification workflow retains only the unsigned submission,
   checksum and non-secret lineage JSON under an exact local NTFS ACL permitting
   only the runner account, SYSTEM and Administrators. It never uploads an MSIX
   to GitHub or retains the QA certificate/copy; the separate GitHub workflow publishes only its
   non-Store portable ZIP and checksum.
5. After QA, uninstall the app and verify the PFN/LocalState directory is gone.
   Delete the exact `CurrentUser\My` development certificate with
   `Remove-Item -DeleteKey`, bound to its validated thumbprint and current-user
   software-CNG key name/unique name/provider. Require the post-cleanup CNG file
   inventory to equal the pre-create baseline; remove the Root/TrustedPeople
   public copies only by that same thumbprint.

Record this as a manual privacy/release gate; do not claim the application can
change a user's OneDrive or Windows Backup settings itself.

## Submission and state tracking

1. On the same protected self-hosted runner, open the exact run-owned directory
   beneath the pre-provisioned local fixed-NTFS `AegisStoreHandoff` root. Require
   the unsigned MSIX, `STORE-SUBMISSION-SHA256.txt`,
   `store-submission-lineage.json` and `private-handoff-receipt.json`; revalidate
   its frozen directory and per-file ACL hashes, recompute each recorded file
   SHA-256, and confirm
   `Get-AuthenticodeSignature` is `NotSigned`. Do not upload the temporary signed
   QA copy. Delete the retained directory only after submission records and a
   separate recoverable archive are confirmed according to the operator policy.
2. Upload that exact unsigned reviewed package to Store ID `9NWTH4KJX5GW` in
   Partner Center. Microsoft Store applies its distribution signature after
   submission; absence of a development signature is intentional. Microsoft
   documents that Store-distributed packages are signed by the Store:
   <https://learn.microsoft.com/en-us/windows/msix/package/sign-msix-package-guide>.
3. Complete IARC, market, pricing, rights, privacy and financial-content forms
   from actual package behavior. Select no transaction/account capability.
4. Treat `uploaded`, `validation passed`, `in certification`, `certified` and
   `publicly available` as distinct states. Record submission ID and timestamps.
5. Microsoft Store signing/certification is separate from CI development
   signing and WACK PASS.
