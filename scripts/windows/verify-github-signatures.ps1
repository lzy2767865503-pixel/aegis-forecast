[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Root,
    [string]$ExpectedThumbprint = ""
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true
Set-StrictMode -Version Latest
if (-not $IsWindows) { throw "Trusted Authenticode verification requires Windows." }
$ExactExpectedThumbprint = $ExpectedThumbprint.Trim().ToUpperInvariant()
if ($ExactExpectedThumbprint -and $ExactExpectedThumbprint -cnotmatch "^[0-9A-F]{40}$") { throw "Expected signer thumbprint is invalid." }
. (Join-Path $PSScriptRoot "trusted-windows-sdk-tool.ps1")

$RequestedRoot = Get-Item -LiteralPath $Root -Force -ErrorAction Stop
if (($RequestedRoot.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Trusted release root is a reparse point." }
$ExactRoot = (Resolve-Path -LiteralPath $Root).Path
$AllowedSimpleNames = @("LAI ZEYU", "来泽宇")
$CodeSigningOid = "1.3.6.1.5.5.7.3.3"
$TimeStampingOid = "1.3.6.1.5.5.7.3.8"
$Sha256Oid = "2.16.840.1.101.3.4.2.1"
$Rfc3161AttributeOids = @(
    "1.2.840.113549.1.9.16.2.14",
    "1.3.6.1.4.1.311.3.3.1"
)
$LegacyCounterSignatureOid = "1.2.840.113549.1.9.6"
$ValidatedChainThumbprints = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.Security.Cryptography.Pkcs
$Signtool = Get-AegisTrustedWindowsSdkTool -Name "signtool.exe"

function Assert-ReleaseCertificateChainOnce {
    param(
        [Parameter(Mandatory = $true)][Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
        [Parameter(Mandatory = $true)][string]$Label
    )
    if ($ValidatedChainThumbprints.Contains($Certificate.Thumbprint)) { return }
    Assert-AegisOnlineCertificateChain -Certificate $Certificate -Label $Label
    [void]$ValidatedChainThumbprints.Add($Certificate.Thumbprint)
}

function Get-MagicKind([string]$Path) {
    $Stream = [IO.File]::OpenRead($Path)
    try {
        if ($Stream.Length -lt 4) { return "OTHER" }
        $Header = New-Object byte[] 4
        [void]$Stream.Read($Header, 0, 4)
        if ($Header[0] -eq 0x50 -and $Header[1] -eq 0x4B -and $Header[2] -eq 0x03 -and $Header[3] -eq 0x04) { return "ZIP" }
        if ($Header[0] -ne 0x4D -or $Header[1] -ne 0x5A) { return "OTHER" }
        if ($Stream.Length -lt 64) { return "INVALID_MZ" }
        $Stream.Position = 0x3C
        $OffsetBytes = New-Object byte[] 4
        if ($Stream.Read($OffsetBytes, 0, 4) -ne 4) { return "INVALID_MZ" }
        $Offset = [BitConverter]::ToUInt32($OffsetBytes, 0)
        if ($Offset -gt $Stream.Length - 4) { return "INVALID_MZ" }
        $Stream.Position = $Offset
        $Signature = New-Object byte[] 4
        if ($Stream.Read($Signature, 0, 4) -eq 4 -and $Signature[0] -eq 0x50 -and $Signature[1] -eq 0x45 -and $Signature[2] -eq 0 -and $Signature[3] -eq 0) { return "MZ_PE" }
        return "INVALID_MZ"
    } finally { $Stream.Dispose() }
}

function Get-ExactPortableExecutableSignatureBlob([string]$Path) {
    $Stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $Reader = [IO.BinaryReader]::new($Stream)
    try {
        if ($Stream.Length -lt 256 -or $Reader.ReadUInt16() -ne 0x5A4D) { throw "File is not a bounded Portable Executable: $Path" }
        $Stream.Position = 0x3C
        $PeOffset = $Reader.ReadInt32()
        if ($PeOffset -lt 0 -or [int64]$PeOffset + 256 -gt $Stream.Length) { throw "PE header offset is invalid: $Path" }
        $Stream.Position = $PeOffset
        if ($Reader.ReadUInt32() -ne 0x00004550) { throw "PE signature is missing: $Path" }
        $OptionalHeader = [int64]$PeOffset + 24
        $Stream.Position = [int64]$PeOffset + 20
        $OptionalHeaderSize = [int64]$Reader.ReadUInt16()
        $Stream.Position = $OptionalHeader
        $Magic = $Reader.ReadUInt16()
        $HeaderPolicy = switch ($Magic) {
            0x10B { [pscustomobject]@{ minimumSize = 224; directoryOffset = $OptionalHeader + 96; numberOfDirectoriesOffset = $OptionalHeader + 92 } }
            0x20B { [pscustomobject]@{ minimumSize = 240; directoryOffset = $OptionalHeader + 112; numberOfDirectoriesOffset = $OptionalHeader + 108 } }
            default { throw "Unsupported PE optional-header magic 0x$($Magic.ToString('X')): $Path" }
        }
        if ($OptionalHeaderSize -lt [int64]$HeaderPolicy.minimumSize -or
            $OptionalHeader + $OptionalHeaderSize -gt $Stream.Length -or
            [int64]$HeaderPolicy.directoryOffset + 40 -gt $OptionalHeader + $OptionalHeaderSize) {
            throw "PE optional header is truncated or cannot contain the certificate-table directory: $Path"
        }
        $Stream.Position = [int64]$HeaderPolicy.numberOfDirectoriesOffset
        if ($Reader.ReadUInt32() -lt 5) { throw "PE does not declare the certificate-table data directory: $Path" }
        $Stream.Position = [int64]$HeaderPolicy.directoryOffset + (4 * 8)
        $CertificateOffset = [int64]$Reader.ReadUInt32()
        $CertificateTableSize = [int64]$Reader.ReadUInt32()
        if ($CertificateOffset -le 0 -or ($CertificateOffset % 8) -ne 0 -or $CertificateTableSize -lt 8 -or $CertificateTableSize -gt 16777216 -or
            $CertificateOffset + $CertificateTableSize -ne $Stream.Length) {
            throw "PE Authenticode certificate table is absent, not terminal, or out of bounds: $Path"
        }
        $Stream.Position = $CertificateOffset
        $CertificateLength = [int64]$Reader.ReadUInt32()
        $Revision = $Reader.ReadUInt16()
        $CertificateType = $Reader.ReadUInt16()
        if ($CertificateLength -lt 8 -or $CertificateLength -gt $CertificateTableSize -or
            $CertificateType -ne 2 -or $Revision -notin @(0x0100, 0x0200)) {
            throw "PE WIN_CERTIFICATE metadata is invalid or is not PKCS#7: $Path"
        }
        $AlignedCertificateLength = ($CertificateLength + 7) -band (-bnot 7)
        if ($AlignedCertificateLength -ne $CertificateTableSize) {
            throw "PE must contain exactly one aligned WIN_CERTIFICATE entry: $Path"
        }
        $Blob = $Reader.ReadBytes([int]($CertificateLength - 8))
        if ($Blob.Length -ne [int]($CertificateLength - 8)) { throw "PE PKCS#7 signature blob is truncated: $Path" }
        $Padding = $Reader.ReadBytes([int]($CertificateTableSize - $CertificateLength))
        if ($Padding.Length -ne [int]($CertificateTableSize - $CertificateLength) -or @($Padding | Where-Object { $_ -ne 0 }).Count -ne 0) {
            throw "PE WIN_CERTIFICATE padding is truncated or non-zero: $Path"
        }
        return $Blob
    } finally {
        $Reader.Dispose()
        $Stream.Dispose()
    }
}

function Assert-ExactCmsSignature([string]$Path, [string]$ExpectedSignerThumbprint) {
    $Cms = [Security.Cryptography.Pkcs.SignedCms]::new()
    $Cms.Decode((Get-ExactPortableExecutableSignatureBlob $Path))
    if ($Cms.SignerInfos.Count -ne 1) { throw "PE must contain exactly one primary Authenticode signer: $Path" }
    $SignerInfo = $Cms.SignerInfos[0]
    if ($SignerInfo.DigestAlgorithm.Value -cne $Sha256Oid -or -not $SignerInfo.Certificate) {
        throw "PE primary Authenticode signer is missing or is not SHA-256: $Path"
    }
    $UnsignedOids = @($SignerInfo.UnsignedAttributes | ForEach-Object { $_.Oid.Value })
    $Rfc3161Attributes = @($UnsignedOids | Where-Object { $Rfc3161AttributeOids -ccontains $_ })
    if ($Rfc3161Attributes.Count -ne 1 -or $UnsignedOids -ccontains $LegacyCounterSignatureOid) {
        throw "PE must contain exactly one RFC 3161 timestamp attribute and no legacy counter-signature: $Path"
    }
    if ($ExpectedSignerThumbprint -and $SignerInfo.Certificate.Thumbprint -cne $ExpectedSignerThumbprint) {
        throw "CMS signer differs from the exact CKA-loaded LAI certificate: $Path"
    }
    return $SignerInfo.Certificate.Thumbprint
}

function Invoke-BoundedSignToolVerify([string]$Path, [switch]$Verbose) {
    $Arguments = [Collections.Generic.List[string]]::new()
    foreach ($Argument in @("verify", "/pa", "/all", "/tw")) { $Arguments.Add($Argument) }
    if ($Verbose) { $Arguments.Add("/v") }
    $Arguments.Add($Path)
    $Info = [Diagnostics.ProcessStartInfo]::new()
    $Info.FileName = $Signtool
    $Info.UseShellExecute = $false
    $Info.CreateNoWindow = $true
    $Info.RedirectStandardOutput = $true
    $Info.RedirectStandardError = $true
    foreach ($Argument in $Arguments) { [void]$Info.ArgumentList.Add($Argument) }
    $Process = [Diagnostics.Process]::new()
    $Process.StartInfo = $Info
    try {
        if (-not $Process.Start()) { throw "SignTool verification did not start: $Path" }
        $Stdout = $Process.StandardOutput.ReadToEndAsync()
        $Stderr = $Process.StandardError.ReadToEndAsync()
        if (-not $Process.WaitForExit(180000)) {
            try { $Process.Kill($true) } catch { }
            if (-not $Process.WaitForExit(30000)) { throw "SignTool process tree remained after timeout: $Path" }
            throw "SignTool verification exceeded its hard timeout: $Path"
        }
        $Tasks = [Threading.Tasks.Task[]]@($Stdout, $Stderr)
        if (-not [Threading.Tasks.Task]::WaitAll($Tasks, 30000)) { throw "SignTool output pipes did not close: $Path" }
        $Output = $Stdout.GetAwaiter().GetResult() + [Environment]::NewLine + $Stderr.GetAwaiter().GetResult()
        if ($Process.ExitCode -ne 0) { throw "SignTool rejected '$Path' with exit code $($Process.ExitCode)." }
        return $Output
    } finally { $Process.Dispose() }
}

function Assert-SignToolOutputPolicy([string]$CompactOutput, [string]$VerboseOutput, [string]$Path) {
    $Rows = [regex]::Matches($CompactOutput, '(?im)^\s*(?<index>\d+)\s+(?<algorithm>sha(?:1|256|384|512))\s+(?<timestamp>\S+)\s*$')
    if ($Rows.Count -ne 1 -or $Rows[0].Groups['index'].Value -cne '0' -or
        $Rows[0].Groups['algorithm'].Value.ToLowerInvariant() -cne 'sha256' -or
        $Rows[0].Groups['timestamp'].Value.ToUpperInvariant() -cne 'RFC3161') {
        throw "SignTool did not prove exactly one SHA-256/RFC3161 signature index 0: $Path"
    }
    $Indexes = [regex]::Matches($VerboseOutput, '(?im)^\s*Signature Index:\s*(?<index>\d+)(?:\s|$)')
    $FileHashes = [regex]::Matches($VerboseOutput, '(?im)^\s*Hash of file \((?<algorithm>[^)]+)\):\s*[0-9a-f]{64}\s*$')
    if ($Indexes.Count -ne 1 -or $Indexes[0].Groups['index'].Value -cne '0' -or
        $FileHashes.Count -ne 1 -or $FileHashes[0].Groups['algorithm'].Value.ToLowerInvariant() -cne 'sha256' -or
        [regex]::Matches($VerboseOutput, '(?im)^\s*Number of (?:files|signatures) successfully Verified:\s*1\s*$').Count -ne 1 -or
        $VerboseOutput -notmatch '(?im)^\s*Number of warnings:\s*0\s*$' -or
        $VerboseOutput -notmatch '(?im)^\s*Number of errors:\s*0\s*$') {
        throw "SignTool verbose output is not one warning-free SHA-256 signature verification: $Path"
    }
}

function Assert-ZipContainsNoExecutable([string]$Path) {
    $Archive = [IO.Compression.ZipFile]::OpenRead($Path)
    $TotalExpanded = [long]0
    try {
        $Seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($Entry in $Archive.Entries) {
            $Normalized = $Entry.FullName.Replace("\", "/")
            if ([string]::IsNullOrWhiteSpace($Normalized) -or [IO.Path]::IsPathRooted($Normalized) -or $Normalized.Split("/") -contains "..") { throw "Nested ZIP has an unsafe path." }
            if (-not $Seen.Add($Normalized.TrimEnd("/"))) { throw "Nested ZIP has a duplicate case-insensitive entry." }
            if ((($Entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) { throw "Nested ZIP has a symbolic-link entry." }
            $TotalExpanded += [long]$Entry.Length
            if ($Entry.Length -gt 134217728 -or $TotalExpanded -gt 1073741824) { throw "Nested ZIP exceeds the bounded inspection size." }
            if ($Entry.Length -eq 0) { continue }
            $EntryStream = $Entry.Open()
            try {
                $Header = New-Object byte[] 4
                $Read = $EntryStream.Read($Header, 0, 4)
                if ($Read -ge 2 -and $Header[0] -eq 0x4D -and $Header[1] -eq 0x5A) { throw "Nested ZIP embeds an executable MZ payload: $($Entry.FullName)" }
                if ($Read -eq 4 -and $Header[0] -eq 0x50 -and $Header[1] -eq 0x4B -and $Header[2] -eq 0x03 -and $Header[3] -eq 0x04) { throw "Nested ZIP embeds another archive: $($Entry.FullName)" }
            } finally { $EntryStream.Dispose() }
        }
    } finally { $Archive.Dispose() }
}

$AllEntries = @(Get-ChildItem -LiteralPath $ExactRoot -Recurse -Force)
if (@($AllEntries | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 }).Count -ne 0) { throw "Release root contains a reparse-point entry." }
$Files = @($AllEntries | Where-Object { -not $_.PSIsContainer })
if ($Files.Count -eq 0) { throw "Trusted release root is empty." }
$PeFiles = [Collections.Generic.List[IO.FileInfo]]::new()
foreach ($File in $Files) {
    $Kind = Get-MagicKind $File.FullName
    if ($Kind -eq "INVALID_MZ") { throw "Release directory contains an invalid MZ payload: $($File.FullName)" }
    if ($Kind -eq "ZIP") { Assert-ZipContainsNoExecutable $File.FullName }
    if ($Kind -eq "MZ_PE") { $PeFiles.Add($File) }
}
if ($PeFiles.Count -lt 2) { throw "Release directory contains too few discoverable PE files." }
$OneThumbprint = $null
foreach ($File in $PeFiles) {
    $CmsThumbprint = Assert-ExactCmsSignature -Path $File.FullName -ExpectedSignerThumbprint $ExactExpectedThumbprint
    $CompactOutput = Invoke-BoundedSignToolVerify -Path $File.FullName
    $VerboseOutput = Invoke-BoundedSignToolVerify -Path $File.FullName -Verbose
    Assert-SignToolOutputPolicy -CompactOutput $CompactOutput -VerboseOutput $VerboseOutput -Path $File.FullName
    $Signature = Get-AuthenticodeSignature -LiteralPath $File.FullName
    if ($Signature.Status -ne [Management.Automation.SignatureStatus]::Valid -or -not $Signature.SignerCertificate -or -not $Signature.TimeStamperCertificate) { throw "Trusted signer or timestamp is missing/invalid for $($File.Name)." }
    $Signer = $Signature.SignerCertificate
    $SimpleName = $Signer.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)
    if ($SimpleName -cnotin $AllowedSimpleNames) { throw "Public PE signer SimpleName must be exactly LAI ZEYU or 来泽宇." }
    if ($Signer.Thumbprint -cne $CmsThumbprint -or ($ExactExpectedThumbprint -and $Signer.Thumbprint -cne $ExactExpectedThumbprint)) { throw "WinTrust/CMS signer differs from the exact CKA-loaded signer." }
    if ($Signer.Subject -ceq $Signer.Issuer) { throw "Self-issued public PE signatures are forbidden." }
    if (-not (@($Signer.EnhancedKeyUsageList) | Where-Object { $_.ObjectId.Value -ceq $CodeSigningOid })) { throw "Public PE signer lacks the Code Signing EKU." }
    $TimeStamper = $Signature.TimeStamperCertificate
    if ($TimeStamper.Subject -ceq $TimeStamper.Issuer) { throw "Self-issued timestamp authorities are forbidden." }
    $TimestampEkus = @($TimeStamper.EnhancedKeyUsageList | ForEach-Object { $_.ObjectId.Value })
    if ($TimestampEkus.Count -ne 1 -or $TimestampEkus[0] -cne $TimeStampingOid) { throw "Timestamp authority EKU must be exactly Time Stamping." }
    if ($OneThumbprint -and $Signer.Thumbprint -cne $OneThumbprint) { throw "Release PEs were signed by more than one certificate." }
    $OneThumbprint = $Signer.Thumbprint
    Assert-ReleaseCertificateChainOnce -Certificate $Signer -Label "$($File.Name) signer"
    Assert-ReleaseCertificateChainOnce -Certificate $TimeStamper -Label "$($File.Name) timestamp authority"
}
Write-Host "Verified exactly one SHA-256/RFC3161 LAI Authenticode signature with online chains for all $($PeFiles.Count) recursively discovered public PEs."
