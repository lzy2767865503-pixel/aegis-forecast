Set-StrictMode -Version Latest

function Assert-AegisExclusiveSignerClaim {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ExpectedTreeSha256,
        [Parameter(Mandatory = $true)][string]$IngressTreeSha256,
        [Parameter(Mandatory = $true)][string]$VaultTreeSha256,
        [Parameter(Mandatory = $true)][string]$PostCopyIngressTreeSha256,
        [Parameter(Mandatory = $true)][bool]$IngressHadReparsePoint,
        [Parameter(Mandatory = $true)][bool]$VaultHasReparsePoint,
        [Parameter(Mandatory = $true)][bool]$IngressRemoved,
        [Parameter(Mandatory = $true)][bool]$VaultAllowsBuildSid,
        [Parameter(Mandatory = $true)][bool]$VaultOwnerIsSigner
    )
    foreach ($Value in @($ExpectedTreeSha256, $IngressTreeSha256, $VaultTreeSha256, $PostCopyIngressTreeSha256)) {
        if ($Value -cnotmatch '^[0-9a-f]{64}$') {
            throw "Signer-claim tree evidence is not canonical lowercase SHA-256."
        }
    }
    if ($IngressHadReparsePoint -or $VaultHasReparsePoint) {
        throw "Signer claim rejected an ingress junction/reparse point or signer-vault reparse point."
    }
    if ($IngressTreeSha256 -cne $ExpectedTreeSha256 -or
        $VaultTreeSha256 -cne $ExpectedTreeSha256 -or
        $PostCopyIngressTreeSha256 -cne $ExpectedTreeSha256) {
        throw "Signer claim rejected a concurrent ingress replacement or changed vault copy."
    }
    if (-not $IngressRemoved -or $VaultAllowsBuildSid -or -not $VaultOwnerIsSigner) {
        throw "Signer claim did not complete the exclusive build-SID-free vault transition."
    }
    return $true
}
