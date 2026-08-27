Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "trusted-windows-sdk-tool.ps1")

function Assert-AegisWackRunner {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ApprovedFileVersion)

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

    $TrustedKit = Get-AegisTrustedWindowsAppCertificationKit -ApprovedFileVersion $ApprovedFileVersion
    $AppCert = [string]$TrustedKit.path
    $InstalledFileVersion = [string]$TrustedKit.fileVersion

    return [pscustomobject]@{
        appCertPath = [IO.Path]::GetFullPath($AppCert)
        fileVersion = $InstalledFileVersion
        productVersion = [string]$TrustedKit.productVersion
        appCertSha256 = [string]$TrustedKit.sha256
        appCertSignerThumbprint = [string]$TrustedKit.signerThumbprint
        appCertTimestampThumbprint = [string]$TrustedKit.timestampThumbprint
        sessionId = $SessionId
        elevatedAdministrator = $true
    }
}
