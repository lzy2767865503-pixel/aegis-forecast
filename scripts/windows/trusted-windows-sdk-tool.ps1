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
    $Current = $Tool
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
    if (-not $ReachedRoot -or $Tool.VersionInfo.CompanyName -cne "Microsoft Corporation" -or
        $Tool.VersionInfo.OriginalFilename -cne $Tool.Name) {
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

function Get-AegisTrustedWindowsAppCertificationKit {
    param([Parameter(Mandatory = $true)][string]$ApprovedFileVersion)
    if (-not $IsWindows) { throw "App Certification Kit resolution requires Windows." }
    if ($ApprovedFileVersion -cnotmatch '^\d+\.\d+\.\d+\.\d+$') {
        throw "Approved AppCert file version must be a four-part numeric version."
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
    return [pscustomobject]@{
        path = $TrustedPath
        fileVersion = $InstalledFileVersion
        productVersion = $ProductVersion
        sha256 = $Sha256
        signerThumbprint = $Signature.SignerCertificate.Thumbprint.ToLowerInvariant()
        timestampThumbprint = $Signature.TimeStamperCertificate.Thumbprint.ToLowerInvariant()
    }
}
