[CmdletBinding()]
param(
    [ValidateSet("Write", "Verify")][string]$Mode = "Write",
    [string]$BackendRootPath = "",
    [string]$ManifestFilePath = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
Set-Location $ProjectRoot
$BackendRoot = if ($BackendRootPath) { [IO.Path]::GetFullPath($BackendRootPath) } else { Join-Path $ProjectRoot "artifacts\backend\AegisBackend" }
$ManifestPath = if ($ManifestFilePath) { [IO.Path]::GetFullPath($ManifestFilePath) } else { Join-Path $ProjectRoot "artifacts\backend\AegisBackend.SHA256.json" }
if (-not (Test-Path $BackendRoot)) { throw "Frozen backend artifact is missing: $BackendRoot" }

function Get-BackendRows {
    $RootItem = Get-Item -LiteralPath $BackendRoot -Force
    if (($RootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Frozen sidecar root may not be a reparse point." }
    $ReparseEntries = @(
        Get-ChildItem -LiteralPath $BackendRoot -Recurse -Force |
            Where-Object { ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 }
    )
    if ($ReparseEntries.Count -ne 0) { throw "Frozen sidecar contains a reparse-point entry: $($ReparseEntries[0].FullName)" }
    return @(
        Get-ChildItem -LiteralPath $BackendRoot -Recurse -File -Force | Sort-Object FullName | ForEach-Object {
            $Relative = [System.IO.Path]::GetRelativePath($BackendRoot, $_.FullName).Replace("\", "/")
            if ($Relative.StartsWith("../", [StringComparison]::Ordinal) -or [System.IO.Path]::IsPathRooted($Relative)) { throw "Frozen sidecar path escaped its root." }
            [pscustomobject]@{
                path = $Relative
                size = $_.Length
                sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToLowerInvariant()
            }
        }
    )
}

function Get-TreeHash([object[]]$Rows) {
    $Canonical = (($Rows | ForEach-Object { "$($_.sha256) $($_.size) $($_.path)" }) -join "`n") + "`n"
    $Bytes = [System.Text.Encoding]::UTF8.GetBytes($Canonical)
    $Digest = [System.Security.Cryptography.SHA256]::HashData($Bytes)
    return [Convert]::ToHexString($Digest).ToLowerInvariant()
}

if ($Mode -eq "Write") {
    $Rows = @(Get-BackendRows)
    if ($Rows.Count -eq 0) { throw "Frozen sidecar hash manifest may not be empty." }
    $Document = [ordered]@{
        schemaVersion = 2
        product = "Quant Scenario Studio by LAI ZEYU"
        author = "LAI ZEYU（来泽宇）"
        artifact = "AegisBackend"
        algorithm = "SHA-256"
        fileCount = $Rows.Count
        treeSha256 = Get-TreeHash $Rows
        files = $Rows
    }
    $Document | ConvertTo-Json -Depth 5 | Set-Content -Encoding utf8 $ManifestPath
    Write-Host "Recorded frozen sidecar SHA-256 manifest: $ManifestPath"
    return
}

if (-not (Test-Path $ManifestPath)) { throw "Pass-1 sidecar hash manifest is missing." }
$Expected = Get-Content -Raw $ManifestPath | ConvertFrom-Json
$ExpectedKeys = @("schemaVersion", "product", "author", "artifact", "algorithm", "fileCount", "treeSha256", "files")
$ActualKeys = @($Expected.PSObject.Properties.Name)
if (@($ExpectedKeys | Where-Object { $_ -notin $ActualKeys }).Count -ne 0 -or @($ActualKeys | Where-Object { $_ -notin $ExpectedKeys }).Count -ne 0) { throw "Sidecar hash manifest schema is not exact." }
if ($Expected.schemaVersion -ne 2 -or $Expected.product -ne "Quant Scenario Studio by LAI ZEYU" -or $Expected.author -ne "LAI ZEYU（来泽宇）" -or $Expected.artifact -ne "AegisBackend" -or $Expected.algorithm -ne "SHA-256") {
    throw "Sidecar hash manifest identity or authorship is invalid."
}
$ActualRows = @(Get-BackendRows)
if ([int]$Expected.fileCount -ne $ActualRows.Count -or @($Expected.files).Count -ne $ActualRows.Count -or $ActualRows.Count -eq 0) {
    throw "Frozen sidecar file count differs from pass 1."
}
$ActualByPath = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($Row in $ActualRows) {
    if ($ActualByPath.ContainsKey($Row.path)) { throw "Frozen sidecar contains duplicate case-insensitive paths: $($Row.path)" }
    $ActualByPath.Add($Row.path, $Row)
}
$ExpectedPaths = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($Row in @($Expected.files)) {
    $RowKeys = @($Row.PSObject.Properties.Name)
    $ActualRowSchema = (($RowKeys | Sort-Object) -join "|")
    $ExpectedRowSchema = ((@("path", "sha256", "size") | Sort-Object) -join "|")
    if ($ActualRowSchema -cne $ExpectedRowSchema) { throw "Sidecar hash row schema is not exact." }
    if (-not $ExpectedPaths.Add([string]$Row.path)) { throw "Sidecar hash manifest contains a duplicate path: $($Row.path)" }
    if ([string]$Row.path -match "(^|/)\.\.(/|$)" -or [string]$Row.sha256 -cnotmatch "^[0-9a-f]{64}$" -or [long]$Row.size -lt 0) { throw "Sidecar hash manifest contains an invalid row." }
    if (-not $ActualByPath.ContainsKey($Row.path)) { throw "Frozen sidecar file is missing: $($Row.path)" }
    $Actual = $ActualByPath[$Row.path]
    if ([long]$Actual.size -ne [long]$Row.size -or $Actual.sha256 -ne $Row.sha256) {
        throw "Frozen sidecar hash mismatch: $($Row.path)"
    }
}
if ($Expected.treeSha256 -cnotmatch "^[0-9a-f]{64}$" -or $Expected.treeSha256 -cne (Get-TreeHash $ActualRows)) { throw "Frozen sidecar canonical tree hash differs from pass 1." }
Write-Host "Verified pass-2 sidecar is byte-for-byte identical to pass 1 ($($ActualRows.Count) files)."
