Set-StrictMode -Version Latest

function Assert-AegisOnlineCertificateChain {
    param(
        [Parameter(Mandatory = $true)]
        [Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
        [Parameter(Mandatory = $true)]
        [string]$Label,
        [switch]$IgnoreNotTimeValid
    )
    $Chain = [Security.Cryptography.X509Certificates.X509Chain]::new()
    try {
        $Chain.ChainPolicy.RevocationMode = [Security.Cryptography.X509Certificates.X509RevocationMode]::Online
        $Chain.ChainPolicy.RevocationFlag = [Security.Cryptography.X509Certificates.X509RevocationFlag]::ExcludeRoot
        $Chain.ChainPolicy.VerificationFlags = if ($IgnoreNotTimeValid) {
            [Security.Cryptography.X509Certificates.X509VerificationFlags]::IgnoreNotTimeValid
        } else {
            [Security.Cryptography.X509Certificates.X509VerificationFlags]::NoFlag
        }
        $Chain.ChainPolicy.UrlRetrievalTimeout = [TimeSpan]::FromSeconds(60)
        if (-not $Chain.Build($Certificate)) {
            $Failures = @($Chain.ChainStatus | ForEach-Object { "$($_.Status):$($_.StatusInformation.Trim())" }) -join "; "
            throw "$Label did not pass online certificate-chain validation: $Failures"
        }
    } finally {
        $Chain.Dispose()
    }
}

function Assert-AegisTrustedMicrosoftTool {
    param(
        [Parameter(Mandatory = $true)][IO.FileInfo]$Tool,
        [Parameter(Mandatory = $true)][string]$WindowsKitsRoot,
        [Parameter(Mandatory = $true)][string]$Label
    )
    $ExactKitsRoot = [IO.Path]::GetFullPath($WindowsKitsRoot).TrimEnd("\")
    $ToolPath = [IO.Path]::GetFullPath($Tool.FullName)
    if (($Tool.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Label path contains a reparse point: $ToolPath"
    }
    # FileInfo does not expose Parent. Start the ancestor walk at its
    # DirectoryInfo so the same fail-closed reparse check works in PowerShell 7.
    $Current = $Tool.Directory
    $ReachedRoot = $false
    while ($Current) {
        $CurrentPath = [IO.Path]::GetFullPath($Current.FullName).TrimEnd("\")
        if (($Current.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Label path contains a reparse point: $CurrentPath"
        }
        if ($CurrentPath.Equals($ExactKitsRoot, [StringComparison]::OrdinalIgnoreCase)) {
            $ReachedRoot = $true
            break
        }
        $Current = $Current.Parent
    }
    $OriginalFilenameMatches = ([string]$Tool.VersionInfo.OriginalFilename).Equals(
        $Tool.Name,
        [StringComparison]::OrdinalIgnoreCase
    )
    if (-not $ReachedRoot -or $Tool.VersionInfo.CompanyName -cne "Microsoft Corporation" -or
        -not $OriginalFilenameMatches) {
        throw "$Label is outside the exact Windows Kits root or lacks Microsoft Corporation metadata."
    }
    $Signature = Get-AuthenticodeSignature -LiteralPath $Tool.FullName
    $SimpleName = if ($Signature.SignerCertificate) {
        $Signature.SignerCertificate.GetNameInfo(
            [Security.Cryptography.X509Certificates.X509NameType]::SimpleName,
            $false
        )
    } else { "" }
    if ($Signature.Status -ne [Management.Automation.SignatureStatus]::Valid -or
        -not $Signature.SignerCertificate -or -not $Signature.TimeStamperCertificate -or
        $SimpleName -cnotin @("Microsoft Windows", "Microsoft Corporation")) {
        throw "$Label does not have the expected valid timestamped Microsoft Authenticode identity."
    }
    Assert-AegisOnlineCertificateChain -Certificate $Signature.SignerCertificate -Label "$Label Microsoft signer" -IgnoreNotTimeValid
    Assert-AegisOnlineCertificateChain -Certificate $Signature.TimeStamperCertificate -Label "$Label timestamp authority"
    return $Tool.FullName
}

function Get-AegisTrustedWindowsSdkTool {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("makeappx.exe", "signtool.exe")]
        [string]$Name
    )
    if (-not $IsWindows) { throw "$Name resolution requires Windows." }
    $WindowsKitsRoot = [IO.Path]::GetFullPath(
        (Join-Path ([Environment]::GetFolderPath("ProgramFilesX86")) "Windows Kits\10")
    ).TrimEnd("\")
    $BinRoot = Join-Path $WindowsKitsRoot "bin"
    $Candidates = @(
        Get-ChildItem -LiteralPath $BinRoot -Directory -Force -ErrorAction Stop |
            Where-Object { $_.Name -cmatch '^\d+\.\d+\.\d+\.\d+$' } |
            ForEach-Object {
                $ExactPath = Join-Path $_.FullName "x64\$Name"
                if (Test-Path -LiteralPath $ExactPath -PathType Leaf) {
                    Get-Item -LiteralPath $ExactPath -Force
                }
            } |
            Sort-Object { [version]$_.Directory.Parent.Name } -Descending
    )
    if ($Candidates.Count -eq 0) { throw "$Name was not found under a versioned Windows SDK x64 directory." }
    $HighestVersion = [version]$Candidates[0].Directory.Parent.Name
    if (@($Candidates | Where-Object { [version]$_.Directory.Parent.Name -eq $HighestVersion }).Count -ne 1) {
        throw "$Name resolution at the highest installed Windows SDK version is ambiguous."
    }
    return Assert-AegisTrustedMicrosoftTool -Tool $Candidates[0] -WindowsKitsRoot $WindowsKitsRoot -Label $Name
}

function Assert-AegisValidAppPackageSignature {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedCertificateThumbprint,
        [Parameter(Mandatory = $true)][string]$ExpectedCertificateSubject
    )
    if (-not $IsWindows) { throw "App-package signature verification requires Windows." }
    $ExactPath = (Resolve-Path -LiteralPath $Path).Path
    if ([IO.Path]::GetExtension($ExactPath).ToLowerInvariant() -cnotin @('.msix', '.appx')) {
        throw "App-package signature verification requires one exact MSIX or APPX file."
    }
    $ExpectedThumbprint = $ExpectedCertificateThumbprint.Trim().ToUpperInvariant()
    if ($ExpectedThumbprint -cnotmatch '^[0-9A-F]{40}$' -or
        [string]::IsNullOrWhiteSpace($ExpectedCertificateSubject) -or
        $ExpectedCertificateSubject.Length -gt 512 -or $ExpectedCertificateSubject -match '[\r\n]') {
        throw "Expected app-package signer identity is malformed."
    }
    $Signature = Get-AuthenticodeSignature -LiteralPath $ExactPath
    if ($Signature.Status -cnotin @(
            [Management.Automation.SignatureStatus]::Valid,
            [Management.Automation.SignatureStatus]::UnknownError
        ) -or -not $Signature.SignerCertificate -or
        $Signature.SignerCertificate.Thumbprint -cne $ExpectedThumbprint -or
        $Signature.SignerCertificate.Subject -cne $ExpectedCertificateSubject) {
        throw "App-package signature does not expose the exact expected signer certificate."
    }
    $Signtool = Get-AegisTrustedWindowsSdkTool -Name 'signtool.exe'
    & $Signtool verify /pa /all /v $ExactPath | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "Microsoft SignTool rejected the app-package signature with exit code $LASTEXITCODE."
    }
    return $Signature
}

function Get-AegisTrustedWindowsAppCertificationKit {
    param(
        [Parameter(Mandatory = $true)][string]$ApprovedFileVersion,
        [Parameter(Mandatory = $true)][string]$ApprovedSha256,
        [Parameter(Mandatory = $true)][string]$ApprovedSignerSubject,
        [Parameter(Mandatory = $true)][string]$ApprovedSignerThumbprint
    )
    if (-not $IsWindows) { throw "App Certification Kit resolution requires Windows." }
    if ($ApprovedFileVersion -cnotmatch '^\d+\.\d+\.\d+\.\d+$' -or
        $ApprovedSha256 -cnotmatch '^[0-9a-f]{64}$' -or
        $ApprovedSignerThumbprint -cnotmatch '^[0-9a-f]{40}$' -or
        [string]::IsNullOrWhiteSpace($ApprovedSignerSubject) -or
        $ApprovedSignerSubject.Length -gt 512 -or $ApprovedSignerSubject -match '[\r\n]') {
        throw "Protected AppCert file version, SHA-256, signer Subject, or signer thumbprint is malformed."
    }
    $WindowsKitsRoot = [IO.Path]::GetFullPath(
        (Join-Path ([Environment]::GetFolderPath("ProgramFilesX86")) "Windows Kits\10")
    ).TrimEnd("\")
    $Path = Join-Path $WindowsKitsRoot "App Certification Kit\appcert.exe"
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "appcert.exe was not found at the exact Windows App Certification Kit path."
    }
    $Tool = Get-Item -LiteralPath $Path -Force
    $InstalledFileVersion = $Tool.VersionInfo.FileVersionRaw.ToString()
    if ($InstalledFileVersion -cne $ApprovedFileVersion) {
        throw "Installed AppCert file version $InstalledFileVersion differs from approved version $ApprovedFileVersion."
    }
    $TrustedPath = Assert-AegisTrustedMicrosoftTool -Tool $Tool -WindowsKitsRoot $WindowsKitsRoot -Label "appcert.exe"
    $Signature = Get-AuthenticodeSignature -LiteralPath $TrustedPath
    $Sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $TrustedPath).Hash.ToLowerInvariant()
    $ProductVersion = [string]$Tool.VersionInfo.ProductVersion
    if ($Sha256 -cnotmatch '^[0-9a-f]{64}$' -or [string]::IsNullOrWhiteSpace($ProductVersion) -or
        -not $Signature.SignerCertificate -or -not $Signature.TimeStamperCertificate) {
        throw "Approved AppCert tool version/hash/signature evidence is incomplete."
    }
    $SignerSubject = [string]$Signature.SignerCertificate.Subject
    $SignerThumbprint = $Signature.SignerCertificate.Thumbprint.ToLowerInvariant()
    if ($Sha256 -cne $ApprovedSha256 -or $SignerSubject -cne $ApprovedSignerSubject -or
        $SignerThumbprint -cne $ApprovedSignerThumbprint) {
        throw "Installed AppCert hash or exact Authenticode signer identity differs from protected approval."
    }
    return [pscustomobject]@{
        path = $TrustedPath
        fileVersion = $InstalledFileVersion
        productVersion = $ProductVersion
        sha256 = $Sha256
        signerSubject = $SignerSubject
        signerThumbprint = $SignerThumbprint
        timestampThumbprint = $Signature.TimeStamperCertificate.Thumbprint.ToLowerInvariant()
    }
}
