Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "trusted-windows-sdk-tool.ps1")

function Assert-AegisWackRunner {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ApprovedFileVersion,
        [Parameter(Mandatory = $true)][string]$ApprovedSha256,
        [Parameter(Mandatory = $true)][string]$ApprovedSignerSubject,
        [Parameter(Mandatory = $true)][string]$ApprovedSignerThumbprint,
        [Parameter(Mandatory = $true)][int]$ApprovedTestCount,
        [Parameter(Mandatory = $true)][string]$ApprovedTestInventorySha256
    )

    if ($ApprovedTestCount -lt 1 -or $ApprovedTestCount -gt 10000 -or
        $ApprovedTestInventorySha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw "Protected WACK TEST count or inventory SHA-256 is malformed."
    }

    if (-not $IsWindows) { throw "WACK certification requires Windows." }
    if (-not [Environment]::UserInteractive) { throw "WACK requires an active interactive user session." }

    $SessionId = (Get-Process -Id $PID -ErrorAction Stop).SessionId
    if ($SessionId -eq 0 -or @(Get-Process explorer -ErrorAction SilentlyContinue | Where-Object SessionId -eq $SessionId).Count -eq 0) {
        throw "WACK may run only on an active non-session-0 desktop with explorer in the same session."
    }

    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $Principal = [Security.Principal.WindowsPrincipal]::new($Identity)
        if (-not $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            throw "WACK command-line validation must run with an elevated administrator token."
        }
    } finally {
        $Identity.Dispose()
    }

    $TrustedKit = Get-AegisTrustedWindowsAppCertificationKit `
        -ApprovedFileVersion $ApprovedFileVersion `
        -ApprovedSha256 $ApprovedSha256 `
        -ApprovedSignerSubject $ApprovedSignerSubject `
        -ApprovedSignerThumbprint $ApprovedSignerThumbprint
    $AppCert = [string]$TrustedKit.path
    $InstalledFileVersion = [string]$TrustedKit.fileVersion

    return [pscustomobject]@{
        appCertPath = [IO.Path]::GetFullPath($AppCert)
        fileVersion = $InstalledFileVersion
        productVersion = [string]$TrustedKit.productVersion
        appCertSha256 = [string]$TrustedKit.sha256
        appCertSignerSubject = [string]$TrustedKit.signerSubject
        appCertSignerThumbprint = [string]$TrustedKit.signerThumbprint
        appCertTimestampThumbprint = [string]$TrustedKit.timestampThumbprint
        approvedTestCount = $ApprovedTestCount
        approvedTestInventorySha256 = $ApprovedTestInventorySha256
        sessionId = $SessionId
        elevatedAdministrator = $true
    }
}
