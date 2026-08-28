[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$WorkingRoot,
    [Parameter(Mandatory = $true)][string]$InstallRoot,
    [Parameter(Mandatory = $true)][string]$StateRoot
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# This companion is intentionally blocked with the repository bootstrap. A
# cleanup that only unloads a certificate or uninstalls CKA is insufficient:
# the approved out-of-band signer must capture the certificate-store, CNG KSP
# provider and private-key baselines before loading, call DeleteKey only for
# exact run-created key identities, unregister only the run-created provider,
# and prove all three baselines were restored in trusted-signing-receipt.json.
foreach ($Path in @($WorkingRoot, $InstallRoot, $StateRoot)) {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw "Disabled repository CKA cleanup received an empty path." }
}
throw @"
Fail-closed: repository-managed CKA cleanup is disabled. No workflow may invoke
it. The separately administered no-checkout signer orchestrator must prove
DeleteKey was attempted for exact run-created keys and that certificate-store,
CNG provider, private-key, CKA user-state, and temporary-client baselines were
fully restored before any signed artifact can leave the signer account.
"@
