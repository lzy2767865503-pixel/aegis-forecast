[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PortableRoot,
    [Parameter(Mandatory = $true)][string]$ArchivePath
)
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
if ($env:AEGIS_TRUSTED_GITHUB_BUILD -cne "1") { throw "Public archive creation is restricted to the protected release workflow." }
$RequestedRoot = Get-Item -LiteralPath $PortableRoot -Force -ErrorAction Stop
if (($RequestedRoot.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Portable archive source root is a reparse point." }
$Root = (Resolve-Path $PortableRoot).Path
$Archive = [IO.Path]::GetFullPath($ArchivePath)
$ReleaseRoot = [IO.Path]::GetFullPath((Join-Path (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path "artifacts\github-release")).TrimEnd("\") + "\"
if (-not $Archive.StartsWith($ReleaseRoot, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetExtension($Archive) -cne ".zip") { throw "Release archive path is invalid." }
$Checksum = $Archive + ".sha256"
if ((Test-Path -LiteralPath $Archive) -or (Test-Path -LiteralPath $Checksum)) { throw "Release archive and checksum must not preexist." }
$PortableEntries = @(Get-ChildItem -LiteralPath $Root -Recurse -Force)
if (@($PortableEntries | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 }).Count -ne 0) { throw "Portable directory contains a reparse-point entry." }
foreach ($File in @($PortableEntries | Where-Object { -not $_.PSIsContainer })) {
    if ($File.Extension.ToLowerInvariant() -in @(".msix", ".appx", ".cer", ".crt", ".der", ".pem", ".p12", ".pfx", ".pvk", ".key")) { throw "Portable directory contains a forbidden Store package or certificate/key container." }
}
$TopLevel = "QuantScenarioStudio-by-LAI-ZEYU-1.5.0-x64"
$StagingParent = Join-Path ([IO.Path]::GetDirectoryName($Archive)) "archive-root"
$StagingProduct = Join-Path $StagingParent $TopLevel
if (Test-Path -LiteralPath $StagingParent) { throw "Archive staging root must not preexist." }
$PrimaryFailure = $null
$Completed = $false
$Hash = $null
try {
    New-Item -ItemType Directory -Path $StagingProduct | Out-Null
    foreach ($Child in @(Get-ChildItem -LiteralPath $Root -Force)) {
        Copy-Item -LiteralPath $Child.FullName -Destination $StagingProduct -Recurse -Force
    }
    Compress-Archive -LiteralPath $StagingProduct -DestinationPath $Archive -CompressionLevel Optimal
    $VerificationRoot = Join-Path $StagingParent 'verified-extraction'
    $ArchiveEvidence = & (Join-Path $PSScriptRoot 'verify-portable-archive.ps1') -ArchivePath $Archive -DestinationPath $VerificationRoot
    if ($ArchiveEvidence.inventorySha256 -cnotmatch '^[0-9a-f]{64}$' -or
        [int]$ArchiveEvidence.entryCount -lt 3 -or [int]$ArchiveEvidence.fileCount -lt 2) {
        throw "New portable ZIP did not produce a complete safe-entry inventory."
    }
    $Hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $Archive).Hash.ToLowerInvariant()
    "$Hash  $([IO.Path]::GetFileName($Archive))" | Set-Content -Encoding ascii $Checksum
    $Completed = $true
} catch {
    $PrimaryFailure = $_.Exception
} finally {
    $Errors = [Collections.Generic.List[string]]::new()
    if ($PrimaryFailure) { $Errors.Add("archive: $($PrimaryFailure.Message)") }
    foreach ($OwnedPath in @($StagingParent) + $(if ($Completed) { @() } else { @($Archive, $Checksum) })) {
        try {
            if (Test-Path -LiteralPath $OwnedPath) {
                $Item = Get-Item -LiteralPath $OwnedPath -Force
                if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Owned archive work product is a reparse point." }
                if ($Item.PSIsContainer) {
                    $Reparse = @(Get-ChildItem -LiteralPath $OwnedPath -Force -Recurse -ErrorAction Stop | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 })
                    if ($Reparse.Count -ne 0) { throw "Owned archive work tree contains a reparse point." }
                    Remove-Item -LiteralPath $OwnedPath -Recurse -Force -ErrorAction Stop
                } else { Remove-Item -LiteralPath $OwnedPath -Force -ErrorAction Stop }
            }
            if (Test-Path -LiteralPath $OwnedPath) { throw "Owned archive work product remained after cleanup." }
        } catch { $Errors.Add("$OwnedPath`: $($_.Exception.Message)") }
    }
    if ($Errors.Count -ne 0) { throw "Portable archive creation/cleanup failures: $($Errors -join ' | ')" }
}
Write-Host "Created trusted portable ZIP $Archive ($Hash)."
