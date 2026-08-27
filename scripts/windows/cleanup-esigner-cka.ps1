[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$WorkingRoot,
    [Parameter(Mandatory = $true)][string]$InstallRoot,
    [Parameter(Mandatory = $true)][string]$StateRoot
)
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
if (-not $env:RUNNER_TEMP) { throw "RUNNER_TEMP is required for CKA cleanup." }
$RunnerPrefix = [IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd("\") + "\"
$ExactWorking = [IO.Path]::GetFullPath($WorkingRoot)
$ExactInstall = [IO.Path]::GetFullPath($InstallRoot)
if (-not $ExactWorking.StartsWith($RunnerPrefix, [StringComparison]::OrdinalIgnoreCase) -or -not $ExactInstall.StartsWith($ExactWorking.TrimEnd("\") + "\", [StringComparison]::OrdinalIgnoreCase)) { throw "Refusing CKA cleanup outside this run's RUNNER_TEMP root." }
$ExpectedState = [IO.Path]::GetFullPath((Join-Path $env:APPDATA "eSignerCKA"))
if ([IO.Path]::GetFullPath($StateRoot) -cne $ExpectedState) { throw "Refusing to remove an unexpected CKA state root." }
if (-not (Test-Path -LiteralPath $ExactWorking)) {
    $PermittedNames = @("LAI ZEYU", "来泽宇")
    $PermittedSignerResidue = @(
        Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert |
            Where-Object { $PermittedNames -ccontains $_.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false) }
    )
    if ((Test-Path -LiteralPath $ExpectedState) -or $PermittedSignerResidue.Count -ne 0) {
        throw "The owned CKA root is missing while signer state or an exact-name code-signing certificate remains."
    }
    Write-Host "No owned temporary CKA root or signer state was created."
    return
}
$WorkingItem = Get-Item -LiteralPath $ExactWorking -Force
if (($WorkingItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Refusing a reparse-point CKA working root." }
$OwnershipPath = Join-Path $ExactWorking ".aegis-cka-owned.json"
if (-not (Test-Path -LiteralPath $OwnershipPath)) { throw "Refusing to clean an unmarked CKA working root." }
$OwnershipItem = Get-Item -LiteralPath $OwnershipPath -Force
if (($OwnershipItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Refusing a reparse-point CKA ownership marker." }
$Ownership = Get-Content -Raw -LiteralPath $OwnershipPath | ConvertFrom-Json
$OwnershipKeys = @($Ownership.PSObject.Properties.Name | Sort-Object)
$ExpectedOwnershipKeys = @("githubRunAttempt", "githubRunId", "installRoot", "ownedSignerThumbprints", "preexistingMyThumbprints", "schemaVersion", "signerThumbprint", "stateRoot", "uninstallerSha256", "workingRoot")
if (($OwnershipKeys -join "|") -cne ($ExpectedOwnershipKeys -join "|")) { throw "CKA cleanup ownership schema is not exact." }
$OwnedSignerThumbprints = @($Ownership.ownedSignerThumbprints)
$UniqueOwnedSignerThumbprints = @($OwnedSignerThumbprints | Sort-Object -Unique)
$PreexistingMyThumbprints = @($Ownership.preexistingMyThumbprints)
$UniquePreexistingMyThumbprints = @($PreexistingMyThumbprints | Sort-Object -Unique)
if ($Ownership.schemaVersion -ne 4 -or $Ownership.githubRunId -cne $env:GITHUB_RUN_ID -or $Ownership.githubRunAttempt -cne $env:GITHUB_RUN_ATTEMPT -or
    [IO.Path]::GetFullPath([string]$Ownership.workingRoot) -cne $ExactWorking -or [IO.Path]::GetFullPath([string]$Ownership.installRoot) -cne $ExactInstall -or
    [IO.Path]::GetFullPath([string]$Ownership.stateRoot) -cne [IO.Path]::GetFullPath($StateRoot) -or
    $UniqueOwnedSignerThumbprints.Count -ne $OwnedSignerThumbprints.Count -or
    $UniquePreexistingMyThumbprints.Count -ne $PreexistingMyThumbprints.Count -or
    @($OwnedSignerThumbprints | Where-Object { $_ -cnotmatch "^[0-9A-F]{40}$" }).Count -ne 0 -or
    @($PreexistingMyThumbprints | Where-Object { $_ -cnotmatch "^[0-9A-F]{40}$" }).Count -ne 0 -or
    @($OwnedSignerThumbprints | Where-Object { $_ -in $PreexistingMyThumbprints }).Count -ne 0 -or
    ([string]$Ownership.uninstallerSha256 -and [string]$Ownership.uninstallerSha256 -cnotmatch '^[0-9a-f]{64}$') -or
    ([string]$Ownership.signerThumbprint -and ([string]$Ownership.signerThumbprint -cnotmatch "^[0-9A-F]{40}$" -or [string]$Ownership.signerThumbprint -cnotin $OwnedSignerThumbprints))) { throw "CKA cleanup ownership marker does not match this GitHub run." }
$Tool = Join-Path $ExactInstall "eSignerCKATool.exe"
$Errors = [Collections.Generic.List[string]]::new()
if (Test-Path -LiteralPath $Tool) {
    $Unload = $null
    try {
        $ToolItem = Get-Item -LiteralPath $Tool -Force
        if (($ToolItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Refusing a reparse-point CKA unload tool." }
        $Info = [Diagnostics.ProcessStartInfo]::new()
        $Info.FileName = $Tool
        $Info.UseShellExecute = $false
        $Info.CreateNoWindow = $true
        [void]$Info.ArgumentList.Add("unload")
        $Unload = [Diagnostics.Process]::new()
        $Unload.StartInfo = $Info
        if (-not $Unload.Start()) { throw "SSL.com CKA unload did not start." }
        if (-not $Unload.WaitForExit(180000)) {
            try { $Unload.Kill($true) } catch { }
            if (-not $Unload.WaitForExit(30000)) { throw "SSL.com CKA unload timed out and its process tree remained." }
            throw "SSL.com CKA unload exceeded its hard timeout."
        }
        if ($Unload.ExitCode -ne 0) { throw "SSL.com CKA certificate unload failed with exit code $($Unload.ExitCode)." }
    } catch { $Errors.Add("unload: $($_.Exception.Message)")
    } finally {
        if ($Unload) {
            try {
                if (-not $Unload.HasExited) {
                    $Unload.Kill($true)
                    if (-not $Unload.WaitForExit(30000)) { throw "SSL.com CKA unload process tree remained during fail-safe cleanup." }
                }
            } catch { $Errors.Add("unload fail-safe: $($_.Exception.Message)") }
            try { $Unload.Dispose() } catch { $Errors.Add("unload dispose: $($_.Exception.Message)") }
        }
    }
}
$PreexistingMySet = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($Thumbprint in $PreexistingMyThumbprints) { [void]$PreexistingMySet.Add($Thumbprint) }
$PostUnloadNewThumbprints = @(
    Get-ChildItem Cert:\CurrentUser\My |
        ForEach-Object { [string]$_.Thumbprint } |
        Where-Object { -not $PreexistingMySet.Contains($_) }
)
$OwnedSignerThumbprints = @($OwnedSignerThumbprints + $PostUnloadNewThumbprints | Sort-Object -Unique)
foreach ($OwnedThumbprint in $OwnedSignerThumbprints) {
    try {
        $CertificatePath = "Cert:\CurrentUser\My\$OwnedThumbprint"
        if (Test-Path -LiteralPath $CertificatePath) {
            $OwnedCertificate = Get-Item -LiteralPath $CertificatePath -ErrorAction Stop
            if ($OwnedCertificate.Thumbprint -cne $OwnedThumbprint) { throw "Exact owned certificate lookup returned a different thumbprint." }
            Remove-Item -LiteralPath $CertificatePath -Force -ErrorAction Stop
        }
        if (Test-Path -LiteralPath $CertificatePath) { throw "Exact run-owned CKA certificate remains after cleanup." }
    } catch { $Errors.Add("certificate $OwnedThumbprint`: $($_.Exception.Message)") }
}
$Uninstaller = Join-Path $ExactInstall "unins000.exe"
if ([string]$Ownership.uninstallerSha256) {
    try {
        if (-not (Test-Path -LiteralPath $Uninstaller -PathType Leaf)) { throw "The exact owned SSL.com CKA uninstaller is missing." }
        $UninstallerItem = Get-Item -LiteralPath $Uninstaller -Force
        if (($UninstallerItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            (Get-FileHash -Algorithm SHA256 -LiteralPath $UninstallerItem.FullName).Hash.ToLowerInvariant() -cne [string]$Ownership.uninstallerSha256) {
            throw "The exact owned SSL.com CKA uninstaller changed."
        }
        $UninstallProcess = [Diagnostics.Process]::new()
        $UninstallStarted = $false
        try {
            $UninstallInfo = [Diagnostics.ProcessStartInfo]::new()
            $UninstallInfo.FileName = $UninstallerItem.FullName
            $UninstallInfo.UseShellExecute = $false
            $UninstallInfo.CreateNoWindow = $true
            foreach ($Argument in @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART')) { [void]$UninstallInfo.ArgumentList.Add($Argument) }
            $UninstallProcess.StartInfo = $UninstallInfo
            if (-not $UninstallProcess.Start()) { throw "SSL.com CKA uninstaller did not start." }
            $UninstallStarted = $true
            if (-not $UninstallProcess.WaitForExit(300000)) {
                try { $UninstallProcess.Kill($true) } catch { }
                if (-not $UninstallProcess.WaitForExit(30000)) { throw "SSL.com CKA uninstaller process tree remained after timeout." }
                throw "SSL.com CKA uninstaller exceeded its hard timeout."
            }
            if ($UninstallProcess.ExitCode -ne 0) { throw "SSL.com CKA uninstaller returned $($UninstallProcess.ExitCode)." }
        } finally {
            if ($UninstallStarted -and -not $UninstallProcess.HasExited) {
                try {
                    $UninstallProcess.Kill($true)
                    [void]$UninstallProcess.WaitForExit(30000)
                } catch { }
            }
            $UninstallProcess.Dispose()
        }
    } catch { $Errors.Add("uninstall: $($_.Exception.Message)") }
} elseif (Test-Path -LiteralPath $Uninstaller) {
    $Errors.Add("uninstall: an unowned SSL.com CKA uninstaller exists and was not executed")
}
$RemainingNewThumbprints = @(
    Get-ChildItem Cert:\CurrentUser\My |
        ForEach-Object { [string]$_.Thumbprint } |
        Where-Object { -not $PreexistingMySet.Contains($_) }
)
if ($RemainingNewThumbprints.Count -ne 0) {
    $Errors.Add("certificate: a certificate-store entry created after CKA setup remains")
}
foreach ($OwnedRoot in @($ExactWorking, $ExpectedState)) {
    try {
        if (Test-Path -LiteralPath $OwnedRoot) {
            $ReparseEntries = @(
                Get-ChildItem -LiteralPath $OwnedRoot -Force -Recurse -ErrorAction Stop |
                    Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 }
            )
            $RootItem = Get-Item -LiteralPath $OwnedRoot -Force
            if (($RootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $ReparseEntries.Count -ne 0) { throw "Owned cleanup tree contains a reparse point." }
            Remove-Item -LiteralPath $OwnedRoot -Recurse -Force -ErrorAction Stop
        }
        if (Test-Path -LiteralPath $OwnedRoot) { throw "Owned cleanup root remained after removal." }
    } catch { $Errors.Add("root $OwnedRoot`: $($_.Exception.Message)") }
}
if ($Errors.Count -ne 0) { throw "Temporary SSL.com signer cleanup failed: $($Errors -join ' | ')" }
Write-Host "Unloaded and removed the temporary SSL.com CKA client, master key and user state."
