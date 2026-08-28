[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SubmissionMsixPath,
    [Parameter(Mandatory = $true)][string]$QaMsixPath,
    [string]$ExpectedQaCertificateThumbprint = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
if (-not $IsWindows) { throw "MSIX submission/QA equivalence verification requires Windows." }
Add-Type -AssemblyName System.IO.Compression.FileSystem

$SubmissionPath = (Resolve-Path -LiteralPath $SubmissionMsixPath).Path
$QaPath = (Resolve-Path -LiteralPath $QaMsixPath).Path
if ($SubmissionPath.Equals($QaPath, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Unsigned submission and signed QA MSIX paths must be different files."
}
$ExpectedThumbprint = $ExpectedQaCertificateThumbprint.Trim().ToUpperInvariant()
if ($ExpectedThumbprint -and $ExpectedThumbprint -cnotmatch '^[0-9A-F]{40}$') { throw "Expected QA certificate thumbprint is invalid." }

function Get-MsixInventory {
    param([Parameter(Mandatory = $true)][string]$Path)
    $Archive = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $Rows = [Collections.Generic.List[object]]::new()
        $Seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $SignatureCount = 0
        $TotalExpanded = [long]0
        foreach ($Entry in $Archive.Entries) {
            $Name = $Entry.FullName.Replace("\", "/")
            if ([string]::IsNullOrWhiteSpace($Name) -or [IO.Path]::IsPathRooted($Name) -or $Name.Split("/") -contains "..") {
                throw "MSIX contains an unsafe entry path: $Name"
            }
            if (-not $Seen.Add($Name.TrimEnd("/"))) { throw "MSIX contains a duplicate case-insensitive entry: $Name" }
            if ((($Entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) { throw "MSIX contains a symbolic-link entry: $Name" }
            $TotalExpanded += [long]$Entry.Length
            if ($Entry.Length -gt 536870912 -or $TotalExpanded -gt 4294967296) { throw "MSIX expanded content exceeds the bounded verification size." }
            if ($Name -ceq "AppxSignature.p7x") {
                $SignatureCount++
                if ($Entry.Length -lt 8 -or $Entry.Length -gt 16777216) { throw "MSIX AppxSignature.p7x size is invalid." }
                continue
            }
            $Stream = $Entry.Open()
            $Hasher = [Security.Cryptography.SHA256]::Create()
            try { $Hash = [Convert]::ToHexString($Hasher.ComputeHash($Stream)).ToLowerInvariant() }
            finally { $Hasher.Dispose(); $Stream.Dispose() }
            $Rows.Add([pscustomobject]@{ path = $Name; size = [long]$Entry.Length; sha256 = $Hash })
        }
        foreach ($Required in @("AppxManifest.xml", "AppxBlockMap.xml", "[Content_Types].xml")) {
            if (@($Rows | Where-Object { $_.path -ceq $Required }).Count -ne 1) { throw "MSIX must contain exactly one $Required entry." }
        }
        $Keys = [string[]]@($Rows | ForEach-Object path)
        [Array]::Sort($Keys, [StringComparer]::Ordinal)
        $ByPath = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
        foreach ($Row in $Rows) { $ByPath.Add([string]$Row.path, $Row) }
        $Canonical = (($Keys | ForEach-Object { $Row = $ByPath[$_]; "$($Row.sha256) $($Row.size) $($Row.path)" }) -join "`n") + "`n"
        $TreeHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Canonical))).ToLowerInvariant()
        return [pscustomobject]@{
            rows = @($Rows)
            signatureCount = $SignatureCount
            payloadFileCount = $Rows.Count
            payloadTreeSha256 = $TreeHash
        }
    } finally { $Archive.Dispose() }
}

$SubmissionInventory = Get-MsixInventory -Path $SubmissionPath
$QaInventory = Get-MsixInventory -Path $QaPath
if ($SubmissionInventory.signatureCount -ne 0) { throw "Partner Center submission MSIX must remain unsigned and contain no AppxSignature.p7x." }
if ($QaInventory.signatureCount -ne 1) { throw "Temporary QA MSIX must contain exactly one AppxSignature.p7x." }
if ($SubmissionInventory.payloadFileCount -ne $QaInventory.payloadFileCount -or
    $SubmissionInventory.payloadTreeSha256 -cne $QaInventory.payloadTreeSha256) {
    throw "Unsigned submission and signed QA MSIX payload trees differ."
}
$QaByPath = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
foreach ($Row in $QaInventory.rows) { $QaByPath.Add([string]$Row.path, $Row) }
foreach ($Row in $SubmissionInventory.rows) {
    if (-not $QaByPath.ContainsKey([string]$Row.path)) { throw "QA MSIX is missing submission payload entry: $($Row.path)" }
    $QaRow = $QaByPath[[string]$Row.path]
    if ([long]$QaRow.size -ne [long]$Row.size -or [string]$QaRow.sha256 -cne [string]$Row.sha256) {
        throw "Submission/QA payload bytes differ: $($Row.path)"
    }
}

$SubmissionSignature = Get-AuthenticodeSignature -LiteralPath $SubmissionPath
if ($SubmissionSignature.Status -ne [Management.Automation.SignatureStatus]::NotSigned -or $SubmissionSignature.SignerCertificate) {
    throw "Partner Center handoff MSIX is not provably unsigned."
}
$QaSignature = Get-AuthenticodeSignature -LiteralPath $QaPath
if ($QaSignature.Status -notin @(
        [Management.Automation.SignatureStatus]::Valid,
        [Management.Automation.SignatureStatus]::UnknownError
    ) -or -not $QaSignature.SignerCertificate -or
    ($ExpectedThumbprint -and $QaSignature.SignerCertificate.Thumbprint -cne $ExpectedThumbprint)) {
    throw "Temporary QA MSIX does not expose the expected technical-Publisher development signature."
}

return [pscustomobject]@{
    submissionPackageSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $SubmissionPath).Hash.ToLowerInvariant()
    submissionPackageSize = (Get-Item -LiteralPath $SubmissionPath).Length
    qaPackageSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $QaPath).Hash.ToLowerInvariant()
    qaPackageSize = (Get-Item -LiteralPath $QaPath).Length
    payloadFileCount = $SubmissionInventory.payloadFileCount
    payloadTreeSha256 = $SubmissionInventory.payloadTreeSha256
}
