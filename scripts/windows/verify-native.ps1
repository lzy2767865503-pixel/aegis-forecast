[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$MsixPath,
    [Parameter(Mandatory = $true)][string]$CandidateManifestPath,
    [Parameter(Mandatory = $true)][string]$CertificatePath,
    [Parameter(Mandatory = $true)][ValidateSet("1", "2")][string]$QaRound
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "trusted-windows-sdk-tool.ps1")

function Assert-NativeSuccess([string]$Label) {
    if ($LASTEXITCODE -ne 0) { throw "$Label returned native exit code $LASTEXITCODE." }
}

if (-not $IsWindows) { throw "Native package QA requires Windows." }
$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
Set-Location $ProjectRoot
$PackagePath = (Resolve-Path $MsixPath).Path
$ManifestPath = (Resolve-Path $CandidateManifestPath).Path
$CerPath = (Resolve-Path $CertificatePath).Path
$Candidate = Get-Content -Raw -LiteralPath $ManifestPath | ConvertFrom-Json
$SubmissionPath = (Resolve-Path -LiteralPath (Join-Path ([IO.Path]::GetDirectoryName($ManifestPath)) ([string]$Candidate.submissionPackageFile))).Path
$ExpectedProduct = "Quant Scenario Studio by LAI ZEYU"
$ExpectedAuthor = "LAI ZEYU（来泽宇）"
$ExpectedCopyright = "Copyright © 2026 LAI ZEYU（来泽宇）"
$ExpectedStoreIdentityName = "LAIZEYU.QuantScenarioStudiobyLAIZEYU"
$ExpectedTechnicalPublisher = "CN=A5F91D0A-30C6-48EE-944F-B767FA872BE8"
$EvidenceRoot = Join-Path $ProjectRoot "artifacts\qa\round-$QaRound"
if (Test-Path -LiteralPath $EvidenceRoot) {
    $EvidenceItem = Get-Item -LiteralPath $EvidenceRoot -Force
    $EvidenceReparse = @(Get-ChildItem -LiteralPath $EvidenceRoot -Force -Recurse -ErrorAction Stop | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 })
    if (($EvidenceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $EvidenceReparse.Count -ne 0) { throw "Refusing to reset a reparse-point native QA evidence tree." }
    Remove-Item -LiteralPath $EvidenceRoot -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $EvidenceRoot | Out-Null

if ($Candidate.schemaVersion -ne 3 -or -not $Candidate.signedDevelopmentCandidate -or -not $Candidate.unsignedStoreSubmission) { throw "Candidate manifest schema/signing boundary is invalid." }
if ($Candidate.product -ne $ExpectedProduct -or $Candidate.author -ne $ExpectedAuthor) { throw "Candidate product/author is invalid." }
if ($Candidate.publisherDisplayName -ne "LAI ZEYU" -or $Candidate.uiLanguage -ne "zh-CN" -or $Candidate.developmentCertificateRole -ne "PartnerCenterTechnicalPublisherOnly") { throw "Candidate visible identity/language/technical-certificate role is invalid." }
if ($Candidate.packagePublisher -cne $ExpectedTechnicalPublisher -or $Candidate.certificateSubject -cne $ExpectedTechnicalPublisher) { throw "Candidate technical Publisher differs from this Partner Center account." }
if ($Candidate.packageIdentity -cne $ExpectedStoreIdentityName) { throw "Candidate does not contain the hard-locked Partner Center Identity Name for Store ID 9NWTH4KJX5GW." }
if ([System.IO.Path]::GetFileName($PackagePath) -ne $Candidate.packageFile) { throw "MSIX file name does not match candidate.json." }
if ([System.IO.Path]::GetFileName($SubmissionPath) -cne $Candidate.submissionPackageFile) { throw "Unsigned Store submission file name does not match candidate.json." }
if ([System.IO.Path]::GetFileName($CerPath) -ne $Candidate.certificateFile) { throw "CER file name does not match candidate.json." }
$SourceCommit = (& git rev-parse HEAD).Trim()
Assert-NativeSuccess "git rev-parse HEAD"
if ($SourceCommit -ne $Candidate.sourceCommit) { throw "QA checkout commit does not match the packaged source commit." }

function Assert-CandidateBytes([string]$Stage) {
    $Item = Get-Item -LiteralPath $PackagePath
    $Hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $PackagePath).Hash.ToLowerInvariant()
    if ($Hash -ne $Candidate.packageSha256 -or $Item.Length -ne [long]$Candidate.packageSize) {
        throw "MSIX bytes differ from candidate.json at $Stage."
    }
    $SubmissionItem = Get-Item -LiteralPath $SubmissionPath
    $SubmissionHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $SubmissionPath).Hash.ToLowerInvariant()
    if ($SubmissionHash -cne $Candidate.submissionPackageSha256 -or $SubmissionItem.Length -ne [long]$Candidate.submissionPackageSize) {
        throw "Unsigned Partner Center submission bytes differ from candidate.json at $Stage."
    }
    $Equivalence = & scripts\windows\msix-payload-equivalence.ps1 `
        -SubmissionMsixPath $SubmissionPath `
        -QaMsixPath $PackagePath `
        -ExpectedQaCertificateThumbprint $Candidate.certificateThumbprint
    if ($Equivalence.payloadTreeSha256 -cne $Candidate.payloadTreeSha256 -or
        [int]$Equivalence.payloadFileCount -ne [int]$Candidate.payloadFileCount -or
        $Equivalence.submissionPackageSha256 -cne $Candidate.submissionPackageSha256 -or
        $Equivalence.qaPackageSha256 -cne $Candidate.packageSha256) {
        throw "Unsigned submission and signed QA payload equivalence changed at $Stage."
    }
    return $Hash
}

$PackageHash = Assert-CandidateBytes "native QA round $QaRound start"
$CertificateHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $CerPath).Hash.ToLowerInvariant()
if ($CertificateHash -ne $Candidate.certificateSha256) { throw "Public CER bytes do not match candidate.json." }
$Certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($CerPath)
if ($Certificate.Thumbprint -ne $Candidate.certificateThumbprint -or $Certificate.Subject -cne $ExpectedTechnicalPublisher) {
    throw "Public CER does not match the Partner Center technical Publisher in candidate.json."
}

$PreexistingPackages = @(Get-AppxPackage -Name $Candidate.packageIdentity -ErrorAction SilentlyContinue)
if ($PreexistingPackages.Count -ne 0) { throw "Fail-closed: a package with the candidate identity already exists; QA will not uninstall it." }
$PreexistingProcesses = @(Get-Process -Name "QuantScenarioStudio", "AegisBackend" -ErrorAction SilentlyContinue)
if ($PreexistingProcesses.Count -ne 0) { throw "Fail-closed: a same-named process already exists; QA will not stop it." }
$FallbackRoot = Join-Path $env:LOCALAPPDATA "AegisForecast\LocalState"
if (Test-Path -LiteralPath $FallbackRoot) { throw "Fail-closed: unpackaged fallback LocalState already exists." }
$FallbackParent = Join-Path $env:LOCALAPPDATA "AegisForecast"
$FallbackParentPreexisting = Test-Path -LiteralPath $FallbackParent
if ($FallbackParentPreexisting) {
    $FallbackParentItem = Get-Item -LiteralPath $FallbackParent -Force
    if (($FallbackParentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Fail-closed: unpackaged fallback parent is a reparse point." }
}
$PackagesRoot = Join-Path $env:LOCALAPPDATA "Packages"
$FamilyPrefix = "$($Candidate.packageIdentity)_"
$PreexistingFamilyRoots = @(
    Get-ChildItem -LiteralPath $PackagesRoot -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name.StartsWith($FamilyPrefix, [StringComparison]::OrdinalIgnoreCase) }
)
if ($PreexistingFamilyRoots.Count -ne 0) { throw "Fail-closed: a LocalState/PFN root for the candidate identity already exists." }
$TrustedPeoplePath = "Cert:\CurrentUser\TrustedPeople\$($Certificate.Thumbprint)"
if (Test-Path -LiteralPath $TrustedPeoplePath) { throw "Fail-closed: the exact QA certificate was already trusted." }

$CertificateImportAttempted = $false
$TemporaryRoot = $null
$InstalledFullName = $null
$InstalledFamilyName = $null
$PackageFamilyRoot = $null
$PackageInstallAttempted = $false
$CreatedPackages = @{}
$CreatedFamilyRoots = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$OwnedProcesses = @{}
$BoundaryPreviousData = $env:AEGIS_DATA_ROOT
$BoundaryPreviousBinding = $env:AEGIS_DATA_ROOT_BINDING
$PrimaryFailure = $null

function Test-NativeTreeHasReparsePoint([string]$Root) {
    $Item = Get-Item -LiteralPath $Root -Force -ErrorAction Stop
    if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $true }
    return @(Get-ChildItem -LiteralPath $Root -Force -Recurse -ErrorAction Stop | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 }).Count -ne 0
}

function Capture-NativeOwnedObjects {
    if (-not $PackageInstallAttempted) { return }
    foreach ($Package in @(Get-AppxPackage -Name $Candidate.packageIdentity -ErrorAction SilentlyContinue)) {
        if ($Package.Name -cne $Candidate.packageIdentity -or $Package.Publisher -cne $ExpectedTechnicalPublisher -or
            [string]$Package.Version -cne [string]$Candidate.packageVersion) { continue }
        $PackageFullName = [string]$Package.PackageFullName
        $PackageFamilyName = [string]$Package.PackageFamilyName
        if ([string]::IsNullOrWhiteSpace($PackageFullName) -or [string]::IsNullOrWhiteSpace($PackageFamilyName) -or
            $PackageFullName -cnotmatch "^$([regex]::Escape($Candidate.packageIdentity))_" -or
            -not $PackageFamilyName.StartsWith($FamilyPrefix, [StringComparison]::Ordinal)) { continue }
        $InstallLocation = if ([string]::IsNullOrWhiteSpace([string]$Package.InstallLocation)) { "" } else { [IO.Path]::GetFullPath([string]$Package.InstallLocation).TrimEnd("\") }
        $CreatedPackages[$PackageFullName] = [pscustomobject]@{
            packageFullName = $PackageFullName
            packageFamilyName = $PackageFamilyName
            installLocation = $InstallLocation
        }
        [void]$CreatedFamilyRoots.Add((Join-Path $PackagesRoot $PackageFamilyName))
    }
    foreach ($Process in @(Get-Process -Name "QuantScenarioStudio", "AegisBackend" -ErrorAction SilentlyContinue)) {
        try {
            $Path = [IO.Path]::GetFullPath($Process.Path)
            $Ticks = $Process.StartTime.ToUniversalTime().Ticks
        } catch { continue }
        foreach ($PackageRecord in @($CreatedPackages.Values)) {
            if ([string]::IsNullOrWhiteSpace([string]$PackageRecord.installLocation)) { continue }
            $ExpectedPaths = @(
                [IO.Path]::GetFullPath((Join-Path $PackageRecord.installLocation "QuantScenarioStudio.exe")),
                [IO.Path]::GetFullPath((Join-Path $PackageRecord.installLocation "Backend\AegisBackend.exe"))
            )
            if (@($ExpectedPaths | Where-Object { $Path.Equals($_, [StringComparison]::OrdinalIgnoreCase) }).Count -eq 1) {
                $OwnedProcesses["$($Process.Id)|$Ticks"] = [pscustomobject]@{
                    processId = [int]$Process.Id
                    executablePath = $Path
                    creationTimeUtcTicks = [long]$Ticks
                }
                break
            }
        }
    }
}
try {
    $CertificateImportAttempted = $true
    $Imported = Import-Certificate -FilePath $CerPath -CertStoreLocation "Cert:\CurrentUser\TrustedPeople"
    if ($Imported.Thumbprint -ne $Certificate.Thumbprint -or $Imported.Subject -cne $ExpectedTechnicalPublisher) { throw "Trusted technical certificate identity mismatch." }
    $Signature = Get-AuthenticodeSignature -LiteralPath $PackagePath
    if ($Signature.Status -ne "Valid" -or $Signature.SignerCertificate.Thumbprint -ne $Certificate.Thumbprint -or $Signature.SignerCertificate.Subject -cne $ExpectedTechnicalPublisher) {
        throw "MSIX signature does not match the Partner Center technical Publisher certificate."
    }

    $MakeAppx = Get-AegisTrustedWindowsSdkTool -Name "makeappx.exe"
    $TemporaryRoot = Join-Path $env:RUNNER_TEMP ("aegis-native-qa-$QaRound-" + [guid]::NewGuid().ToString("N"))
    $UnpackRoot = Join-Path $TemporaryRoot "unpacked"
    $BoundaryRoot = Join-Path $TemporaryRoot "boundary-data"
    New-Item -ItemType Directory -Path $UnpackRoot -Force | Out-Null

    & $MakeAppx unpack /p $PackagePath /d $UnpackRoot /o | Out-Host
    Assert-NativeSuccess "makeappx unpack"
    if (@(Get-ChildItem -LiteralPath $UnpackRoot -Force -Recurse -ErrorAction Stop | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 }).Count -ne 0) { throw "Unpacked MSIX contains a reparse-point entry." }
    & scripts\windows\backend-hashes.ps1 -Mode Verify `
        -BackendRootPath (Join-Path $UnpackRoot "Backend") `
        -ManifestFilePath (Join-Path $ProjectRoot "artifacts\backend\AegisBackend.SHA256.json")
    $AppxManifestPath = Join-Path $UnpackRoot "AppxManifest.xml"
    if (-not (Test-Path $AppxManifestPath)) { throw "Unpacked AppxManifest.xml is missing." }
    [xml]$AppxManifest = Get-Content -Raw -LiteralPath $AppxManifestPath
    $Namespace = [System.Xml.XmlNamespaceManager]::new($AppxManifest.NameTable)
    $Namespace.AddNamespace("m", "http://schemas.microsoft.com/appx/manifest/foundation/windows10")
    $Identity = $AppxManifest.SelectSingleNode("/m:Package/m:Identity", $Namespace)
    $Properties = $AppxManifest.SelectSingleNode("/m:Package/m:Properties", $Namespace)
    $Languages = @($AppxManifest.SelectNodes("/m:Package/m:Resources/m:Resource", $Namespace) | ForEach-Object { $_.Language.ToLowerInvariant() })
    if ($Identity.Name -cne $Candidate.packageIdentity -or $Identity.Publisher -cne $ExpectedTechnicalPublisher) { throw "Unpacked package technical identity/publisher is invalid." }
    if ($Identity.Version -ne $Candidate.packageVersion -or $Identity.ProcessorArchitecture -ne "x64") { throw "Unpacked package version/architecture is invalid." }
    if ($Properties.DisplayName -ne $ExpectedProduct -or $Properties.PublisherDisplayName -ne "LAI ZEYU") { throw "Unpacked display/publisher identity is invalid." }
    if ($Languages.Count -ne 1 -or $Languages[0] -ne "zh-cn") { throw "Store v1 must contain exactly the zh-cn resource declaration." }

    foreach ($RequiredLegal in @(
        "Legal\LICENSE.txt",
        "Legal\THIRD_PARTY_NOTICES.md",
        "Legal\DEPENDENCY_LICENSES.md",
        "Backend\Legal\Runtime\RUNTIME_LICENSE_MANIFEST.json",
        "Backend\Legal\NuGet\NUGET_LICENSE_MANIFEST.json"
    )) {
        if (-not (Test-Path (Join-Path $UnpackRoot $RequiredLegal))) { throw "Packaged legal evidence is missing: $RequiredLegal" }
    }
    $ForbiddenPackageNames = "(?i)(^|[\\/])(moomoo|futu|t_trading|t-trader|t_trader|pnl_ledger|us_pipeline)([\\/.]|$)"
    $ForbiddenPaths = @(Get-ChildItem $UnpackRoot -Recurse -Force | Where-Object { $_.FullName.Substring($UnpackRoot.Length) -match $ForbiddenPackageNames })
    if ($ForbiddenPaths.Count -gt 0) { throw "Forbidden Store module/config path was packaged: $($ForbiddenPaths[0].FullName)" }
    $PackagedConfigs = @(Get-ChildItem (Join-Path $UnpackRoot "Backend") -Recurse -File -Filter *.json | Where-Object { $_.Directory.Name -eq "config" } | ForEach-Object { $_.Name } | Sort-Object -Unique)
    $ExpectedConfigs = @("store_model_config.json", "system.json", "us_universe.json") | Sort-Object
    if (($PackagedConfigs -join "|") -ne ($ExpectedConfigs -join "|")) {
        throw "Packaged Store configuration set is not the exact three-file allowlist: $($PackagedConfigs -join ', ')"
    }

    $ShellExe = Join-Path $UnpackRoot "QuantScenarioStudio.exe"
    $BackendExe = Join-Path $UnpackRoot "Backend\AegisBackend.exe"
    if (-not (Test-Path $ShellExe) -or -not (Test-Path $BackendExe)) { throw "Compiled shell or read-only sidecar is missing from the MSIX." }
    $env:AEGIS_DATA_ROOT = $BoundaryRoot
    $env:AEGIS_DATA_ROOT_BINDING = "TEST:native-boundary-$QaRound"
    $BoundaryOutput = @(& $BackendExe --check-packaged-imports 2>&1)
    Assert-NativeSuccess "compiled sidecar dependency-boundary self-check"
    if (-not (($BoundaryOutput -join "`n").Contains("PACKAGED_BOUNDARY_OK=no-account-sdk-no-execution-modules", [StringComparison]::Ordinal))) {
        throw "Compiled sidecar dependency-boundary success token is missing."
    }
    if (Test-Path -LiteralPath $BoundaryRoot) {
        if (@(Get-ChildItem -LiteralPath $BoundaryRoot -Force -ErrorAction SilentlyContinue).Count -ne 0) { throw "Boundary self-check wrote to its isolated data root." }
    }
    if (Test-Path -LiteralPath $FallbackRoot) { throw "Boundary self-check created unpackaged fallback LocalState." }
    $BoundaryFamilyRoots = @(
        Get-ChildItem -LiteralPath $PackagesRoot -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name.StartsWith($FamilyPrefix, [StringComparison]::OrdinalIgnoreCase) }
    )
    if ($BoundaryFamilyRoots.Count -ne 0) { throw "Boundary self-check created a candidate PFN/LocalState root." }
    if ($BoundaryPreviousData) { $env:AEGIS_DATA_ROOT = $BoundaryPreviousData } else { Remove-Item Env:\AEGIS_DATA_ROOT -ErrorAction SilentlyContinue }
    if ($BoundaryPreviousBinding) { $env:AEGIS_DATA_ROOT_BINDING = $BoundaryPreviousBinding } else { Remove-Item Env:\AEGIS_DATA_ROOT_BINDING -ErrorAction SilentlyContinue }

    $Version = (Get-Item -LiteralPath $ShellExe).VersionInfo
    if ($Version.ProductName -ne $ExpectedProduct -or $Version.CompanyName -ne "LAI ZEYU" -or $Version.LegalCopyright -ne $ExpectedCopyright) {
        throw "Compiled EXE VersionInfo product/company/copyright is invalid."
    }
    if ($Version.FileVersion -ne "1.5.0.0" -or $Version.ProductVersion -ne "1.5.0+$SourceCommit") {
        throw "Compiled EXE InformationalVersion must contain the source commit exactly once."
    }
    $FrontendFiles = @(Get-ChildItem (Join-Path $UnpackRoot "Backend") -Recurse -File -Include *.html,*.js)
    if ($FrontendFiles.Count -eq 0) { throw "Packaged frontend files are missing." }
    $FrontendText = ($FrontendFiles | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) }) -join "`n"
    foreach ($Token in @($ExpectedProduct, $ExpectedAuthor, "local-only-no-telemetry", "deterministic-synthetic-2026-08-26", "store-readiness", "DETERMINISTIC_SYNTHETIC_SCENARIO")) {
        if (-not $FrontendText.Contains($Token, [StringComparison]::Ordinal)) { throw "Compiled frontend identity/readiness token is missing: $Token" }
    }
    foreach ($ForbiddenText in @("Moomoo", "OpenD")) {
        if ($FrontendText.Contains($ForbiddenText, [StringComparison]::OrdinalIgnoreCase)) { throw "Compiled Store frontend contains a forbidden connector claim: $ForbiddenText" }
    }

    [pscustomobject]@{
        qaRound = $QaRound
        packageSha256 = $PackageHash
        submissionPackageSha256 = $Candidate.submissionPackageSha256
        payloadTreeSha256 = $Candidate.payloadTreeSha256
        submissionPayloadEquivalent = $true
        sourceCommit = $SourceCommit
        manifestIdentity = $Identity.Name
        packageSigner = $Identity.Publisher
        publisherDisplayName = $Properties.PublisherDisplayName
        language = $Languages[0]
        exeProduct = $Version.ProductName
        exeCompany = $Version.CompanyName
        exeCopyright = $Version.LegalCopyright
        exeProductVersion = $Version.ProductVersion
        packagedLegal = $true
        packagedBackendHashManifestVerified = $true
        packagedConfigAllowlist = $PackagedConfigs
        boundarySelfCheckUsedIsolatedRoot = $true
        fallbackLocalStateAbsent = $true
        forbiddenConnectorModulesAbsent = $true
    } | ConvertTo-Json | Set-Content -Encoding utf8 (Join-Path $EvidenceRoot "static-package-validation.json")
    Copy-Item -LiteralPath $AppxManifestPath -Destination (Join-Path $EvidenceRoot "AppxManifest.xml")

    $PackageInstallAttempted = $true
    Add-AppxPackage -Path $PackagePath
    Capture-NativeOwnedObjects
    $InstalledPackages = @(Get-AppxPackage -Name $Candidate.packageIdentity)
    if ($InstalledPackages.Count -ne 1) { throw "Expected exactly one newly installed candidate package." }
    $Installed = $InstalledPackages[0]
    $InstalledFullName = $Installed.PackageFullName
    $InstalledFamilyName = $Installed.PackageFamilyName
    $InstallLocation = [System.IO.Path]::GetFullPath($Installed.InstallLocation).TrimEnd("\")
    $InstallPrefix = $InstallLocation + "\"
    $PackageFamilyRoot = Join-Path $env:LOCALAPPDATA "Packages\$InstalledFamilyName"
    $LocalState = Join-Path $PackageFamilyRoot "LocalState"
    $Runtime = Join-Path $LocalState "runtime"
    $OwnershipMarkerPath = Join-Path $LocalState ".quant-scenario-localstate.json"
    New-Item -ItemType Directory -Path $Runtime -Force | Out-Null
    $ReadyMarker = Join-Path $Runtime "ui_ready.json"
    if (Test-Path $ReadyMarker) { throw "Readiness marker existed before candidate launch." }
    [ordered]@{
        packageSha256 = $PackageHash
        sourceCommit = $SourceCommit
        qaRound = $QaRound
        nonce = ([Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))).ToLowerInvariant()
    } | ConvertTo-Json | Set-Content -Encoding utf8 (Join-Path $Runtime "qa_expected.json")
    $ExpectedRequest = Get-Content -Raw -LiteralPath (Join-Path $Runtime "qa_expected.json") | ConvertFrom-Json

    Start-Process explorer.exe "shell:AppsFolder\$InstalledFamilyName!App"
    $Marker = $null
    for ($Attempt = 0; $Attempt -lt 180; $Attempt++) {
        if (Test-Path $ReadyMarker) {
            try { $Marker = Get-Content -Raw -LiteralPath $ReadyMarker | ConvertFrom-Json } catch { $Marker = $null }
            if ($Marker) { break }
        }
        Start-Sleep -Milliseconds 500
    }
    if (-not $Marker) { throw "DOM readiness marker was not produced after real API and WebView2 validation." }
    if (-not (Test-Path -LiteralPath $OwnershipMarkerPath)) { throw "Marker-bound LocalState ownership evidence is missing." }
    $OwnershipMarker = Get-Content -Raw -LiteralPath $OwnershipMarkerPath | ConvertFrom-Json
    if ($OwnershipMarker.schemaVersion -ne 1 -or $OwnershipMarker.product -ne $ExpectedProduct -or $OwnershipMarker.binding -ne "PFN:$InstalledFamilyName") {
        throw "LocalState ownership marker identity/PFN binding is invalid."
    }
    if ([System.IO.Path]::GetFullPath([string]$OwnershipMarker.canonicalRoot).TrimEnd("\") -ne [System.IO.Path]::GetFullPath($LocalState).TrimEnd("\")) {
        throw "LocalState ownership marker canonical root is invalid."
    }
    if ($Marker.product -ne $ExpectedProduct -or $Marker.author -ne $ExpectedAuthor -or -not $Marker.readOnly) { throw "DOM readiness product/author/read-only evidence is invalid." }
    if ($Marker.privacy -ne "local-only-no-telemetry" -or $Marker.demo -ne "deterministic-synthetic-2026-08-26" -or $Marker.language -ne "zh-CN") { throw "DOM readiness privacy/demo/language evidence is invalid." }
    if (-not $Marker.apiHealthValidated -or -not $Marker.coreDataValidated -or -not $Marker.domDataReady) { throw "DOM readiness did not prove real health and core-data API success." }
    if ($Marker.sourceCommit -ne $SourceCommit -or $Marker.packageSha256 -ne $PackageHash -or $Marker.qaRound -ne $QaRound) { throw "DOM readiness commit/hash/round evidence is invalid." }
    if ($Marker.nonce -cne $ExpectedRequest.nonce -or [string]$Marker.nonce -cnotmatch "^[0-9a-f]{64}$") { throw "DOM readiness nonce is missing or does not match this launch request." }
    if ($Marker.packageFamily -ne $InstalledFamilyName -or -not $Marker.navigationCompleted) { throw "DOM readiness PFN/navigation evidence is invalid." }
    if ([System.IO.Path]::GetFullPath([string]$Marker.installLocation).TrimEnd("\") -ne $InstallLocation) { throw "DOM marker install location differs from Get-AppxPackage." }
    if ([System.IO.Path]::GetFullPath([string]$Marker.dataRoot).TrimEnd("\") -ne [System.IO.Path]::GetFullPath($LocalState).TrimEnd("\") -or $Marker.dataRootBinding -cne "PFN:$InstalledFamilyName") { throw "DOM marker data-root binding differs from the installed PFN LocalState." }

    $ShellProcessId = [int]$Marker.shellProcessId
    $BackendProcessId = [int]$Marker.backendProcessId
    if ($ShellProcessId -le 0 -or $BackendProcessId -le 0 -or $ShellProcessId -eq $BackendProcessId) { throw "DOM marker process IDs are invalid." }
    $ShellProcess = Get-Process -Id $ShellProcessId -ErrorAction Stop
    $BackendProcess = Get-Process -Id $BackendProcessId -ErrorAction Stop
    if ($ShellProcess.ProcessName -ne "QuantScenarioStudio" -or $BackendProcess.ProcessName -ne "AegisBackend") { throw "DOM marker process names are invalid." }
    $ShellProcessPath = [System.IO.Path]::GetFullPath($ShellProcess.Path)
    $BackendProcessPath = [System.IO.Path]::GetFullPath($BackendProcess.Path)
    $ExpectedShellPath = [System.IO.Path]::GetFullPath((Join-Path $InstallLocation "QuantScenarioStudio.exe"))
    $ExpectedBackendPath = [System.IO.Path]::GetFullPath((Join-Path $InstallLocation "Backend\AegisBackend.exe"))
    if ($ShellProcessPath -ne $ExpectedShellPath -or $BackendProcessPath -ne $ExpectedBackendPath) { throw "Running shell/sidecar paths are not the installed package binaries." }
    if ($Marker.shellExecutablePath -ne $ExpectedShellPath -or $Marker.backendExecutablePath -ne $ExpectedBackendPath) { throw "DOM marker executable paths are invalid." }
    if (-not $ShellProcessPath.StartsWith($InstallPrefix, [StringComparison]::OrdinalIgnoreCase) -or -not $BackendProcessPath.StartsWith($InstallPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Runtime executable escaped the package install location." }
    $MarkerCapturedAt = [DateTimeOffset]::ParseExact([string]$Marker.capturedAt, "o", [Globalization.CultureInfo]::InvariantCulture)
    if ($MarkerCapturedAt -lt [DateTimeOffset]::UtcNow.AddMinutes(-3) -or $MarkerCapturedAt -gt [DateTimeOffset]::UtcNow.AddMinutes(1)) { throw "DOM readiness marker timestamp is not fresh for this launch." }
    # Only after nonce, names and canonical install paths all match may these
    # PIDs become owned cleanup targets.
    $ShellCreationTicks = $ShellProcess.StartTime.ToUniversalTime().Ticks
    $BackendCreationTicks = $BackendProcess.StartTime.ToUniversalTime().Ticks
    $OwnedProcesses["$ShellProcessId|$ShellCreationTicks"] = [pscustomobject]@{ processId = $ShellProcessId; executablePath = $ExpectedShellPath; creationTimeUtcTicks = [long]$ShellCreationTicks }
    $OwnedProcesses["$BackendProcessId|$BackendCreationTicks"] = [pscustomobject]@{ processId = $BackendProcessId; executablePath = $ExpectedBackendPath; creationTimeUtcTicks = [long]$BackendCreationTicks }

    Stop-Process -Id $ShellProcessId -Force
    for ($Attempt = 0; $Attempt -lt 60; $Attempt++) {
        $CurrentBackend = Get-Process -Id $BackendProcessId -ErrorAction SilentlyContinue
        if (-not $CurrentBackend -or $CurrentBackend.StartTime.ToUniversalTime().Ticks -ne $BackendCreationTicks) { break }
        Start-Sleep -Milliseconds 500
    }
    $CurrentShell = Get-Process -Id $ShellProcessId -ErrorAction SilentlyContinue
    $CurrentBackend = Get-Process -Id $BackendProcessId -ErrorAction SilentlyContinue
    if ($CurrentShell -and $CurrentShell.StartTime.ToUniversalTime().Ticks -eq $ShellCreationTicks) { throw "Force-killed shell process remained alive." }
    if ($CurrentBackend -and $CurrentBackend.StartTime.ToUniversalTime().Ticks -eq $BackendCreationTicks) { throw "Sidecar did not exit through the parent-process watchdog after shell force-kill." }
    if (@(Get-Process -Name "QuantScenarioStudio", "AegisBackend" -ErrorAction SilentlyContinue).Count -ne 0) { throw "A same-named runtime process remained after watchdog validation." }

    Remove-AppxPackage -Package $InstalledFullName
    for ($Attempt = 0; $Attempt -lt 60; $Attempt++) {
        $PackageGone = @(Get-AppxPackage -Name $Candidate.packageIdentity -ErrorAction SilentlyContinue).Count -eq 0
        $DataGone = -not (Test-Path $PackageFamilyRoot)
        if ($PackageGone -and $DataGone) { break }
        Start-Sleep -Milliseconds 500
    }
    if (@(Get-AppxPackage -Name $Candidate.packageIdentity -ErrorAction SilentlyContinue).Count -ne 0) { throw "Package remained installed after exact uninstall." }
    $InstalledFullName = $null
    if (Test-Path $PackageFamilyRoot) { throw "PFN/LocalState remained after uninstall." }
    if (Test-Path $FallbackRoot) { throw "Unpackaged fallback LocalState exists after uninstall." }
    if (@(Get-Process -Name "QuantScenarioStudio", "AegisBackend" -ErrorAction SilentlyContinue).Count -ne 0) { throw "Packaged process remained after uninstall." }
    $FinalPackageHash = Assert-CandidateBytes "native QA round $QaRound completion"

    [pscustomobject]@{
        qaRound = $QaRound
        product = $Marker.product
        author = $Marker.author
        technicalPublisher = $ExpectedTechnicalPublisher
        readOnly = $Marker.readOnly
        privacy = $Marker.privacy
        demo = $Marker.demo
        apiHealthValidated = $Marker.apiHealthValidated
        coreDataValidated = $Marker.coreDataValidated
        domDataReady = $Marker.domDataReady
        sourceCommit = $Marker.sourceCommit
        nonce = $Marker.nonce
        packageSha256Before = $PackageHash
        packageSha256After = $FinalPackageHash
        submissionPackageSha256 = $Candidate.submissionPackageSha256
        payloadTreeSha256 = $Candidate.payloadTreeSha256
        submissionPayloadEquivalent = $true
        packageFamily = $Marker.packageFamily
        dataRootBinding = $Marker.dataRootBinding
        installLocation = $InstallLocation
        shellProcessId = $ShellProcessId
        backendProcessId = $BackendProcessId
        shellExecutablePath = $ShellProcessPath
        backendExecutablePath = $BackendProcessPath
        shellForceKilled = $true
        sidecarExitedViaParentWatchdog = $true
        packageAbsentAfterUninstall = $true
        pfnAndLocalStateAbsentAfterUninstall = $true
        fallbackLocalStateAbsentAfterUninstall = $true
        markerBoundLocalStateValidated = $true
        capturedAt = [DateTimeOffset]::UtcNow.ToString("o")
    } | ConvertTo-Json | Set-Content -Encoding utf8 (Join-Path $EvidenceRoot "lifecycle-dom-api-uninstall.json")
} catch {
    $PrimaryFailure = $_.Exception
} finally {
    $FinalErrors = [Collections.Generic.List[string]]::new()
    if ($PrimaryFailure) { $FinalErrors.Add("verification: $($PrimaryFailure.Message)") }
    foreach ($Restore in @(
        [pscustomobject]@{ name = "AEGIS_DATA_ROOT"; value = $BoundaryPreviousData },
        [pscustomobject]@{ name = "AEGIS_DATA_ROOT_BINDING"; value = $BoundaryPreviousBinding }
    )) {
        try {
            if ($Restore.value) { [Environment]::SetEnvironmentVariable($Restore.name, [string]$Restore.value, "Process") }
            else { [Environment]::SetEnvironmentVariable($Restore.name, $null, "Process") }
        } catch { $FinalErrors.Add("environment $($Restore.name): $($_.Exception.Message)") }
    }
    try { Capture-NativeOwnedObjects } catch { $FinalErrors.Add("capture owned native objects: $($_.Exception.Message)") }
    foreach ($Record in @($OwnedProcesses.Values)) {
        try {
            $Created = Get-Process -Id ([int]$Record.processId) -ErrorAction SilentlyContinue
            if (-not $Created -or $Created.StartTime.ToUniversalTime().Ticks -ne [long]$Record.creationTimeUtcTicks) { continue }
            $ActualOwnedPath = [IO.Path]::GetFullPath($Created.Path)
            if (-not $ActualOwnedPath.Equals([string]$Record.executablePath, [StringComparison]::OrdinalIgnoreCase)) { continue }
            Stop-Process -Id ([int]$Record.processId) -Force -ErrorAction Stop
            $Created.WaitForExit(30000)
            $Remaining = Get-Process -Id ([int]$Record.processId) -ErrorAction SilentlyContinue
            if ($Remaining -and $Remaining.StartTime.ToUniversalTime().Ticks -eq [long]$Record.creationTimeUtcTicks) { throw "Owned runtime process remained after cleanup." }
        } catch { $FinalErrors.Add("process $($Record.processId): $($_.Exception.Message)") }
    }
    foreach ($PackageRecord in @($CreatedPackages.Values)) {
        try {
            $PackageFullName = [string]$PackageRecord.packageFullName
            $ExactInstalled = @(Get-AppxPackage -Name $Candidate.packageIdentity -ErrorAction SilentlyContinue | Where-Object { $_.PackageFullName -ceq $PackageFullName -and $_.Publisher -ceq $ExpectedTechnicalPublisher })
            if ($ExactInstalled.Count -gt 1) { throw "More than one exact package record exists." }
            if ($ExactInstalled.Count -eq 1) { Remove-AppxPackage -Package $PackageFullName -ErrorAction Stop }
            for ($Attempt = 0; $Attempt -lt 60; $Attempt++) {
                if (@(Get-AppxPackage -Name $Candidate.packageIdentity -ErrorAction SilentlyContinue | Where-Object PackageFullName -ceq $PackageFullName).Count -eq 0) { break }
                Start-Sleep -Milliseconds 500
            }
            if (@(Get-AppxPackage -Name $Candidate.packageIdentity -ErrorAction SilentlyContinue | Where-Object PackageFullName -ceq $PackageFullName).Count -ne 0) { throw "Exact native QA package remained installed." }
        } catch { $FinalErrors.Add("package $($PackageRecord.packageFullName): $($_.Exception.Message)") }
    }
    foreach ($FamilyRoot in $CreatedFamilyRoots) {
        try {
            $ExactFamilyRoot = [IO.Path]::GetFullPath($FamilyRoot).TrimEnd("\")
            $PackagesPrefix = [IO.Path]::GetFullPath($PackagesRoot).TrimEnd("\") + "\"
            $FamilyName = [IO.Path]::GetFileName($ExactFamilyRoot)
            if (-not $ExactFamilyRoot.StartsWith($PackagesPrefix, [StringComparison]::OrdinalIgnoreCase) -or
                -not $FamilyName.StartsWith($FamilyPrefix, [StringComparison]::Ordinal)) { throw "PFN root escaped the exact candidate boundary." }
            if (@(Get-AppxPackage -Name $Candidate.packageIdentity -ErrorAction SilentlyContinue | Where-Object PackageFamilyName -ceq $FamilyName).Count -ne 0) { throw "Exact candidate package remains installed." }
            if (Test-Path -LiteralPath $ExactFamilyRoot) {
                if (Test-NativeTreeHasReparsePoint $ExactFamilyRoot) { throw "PFN cleanup tree contains a reparse point." }
                Remove-Item -LiteralPath $ExactFamilyRoot -Recurse -Force -ErrorAction Stop
            }
            if (Test-Path -LiteralPath $ExactFamilyRoot) { throw "Exact PFN root remained after cleanup." }
        } catch { $FinalErrors.Add("PFN root $FamilyRoot`: $($_.Exception.Message)") }
    }
    if (Test-Path -LiteralPath $FallbackRoot) {
        try {
            $ExactFallback = [IO.Path]::GetFullPath($FallbackRoot).TrimEnd("\")
            $ExpectedFallback = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA "AegisForecast\LocalState")).TrimEnd("\")
            if (-not $ExactFallback.Equals($ExpectedFallback, [StringComparison]::OrdinalIgnoreCase)) { throw "Fallback root escaped the exact application-data boundary." }
            $OwnerPath = Join-Path $ExactFallback ".quant-scenario-localstate.json"
            if (-not (Test-Path -LiteralPath $OwnerPath -PathType Leaf)) { throw "Fallback root lacks exact application ownership evidence." }
            $Owner = Get-Content -Raw -LiteralPath $OwnerPath | ConvertFrom-Json
            if ($Owner.schemaVersion -ne 1 -or $Owner.product -cne $ExpectedProduct -or $Owner.binding -cne "UNPACKAGED_WINDOWS" -or
                -not [IO.Path]::GetFullPath([string]$Owner.canonicalRoot).TrimEnd("\").Equals($ExactFallback, [StringComparison]::OrdinalIgnoreCase)) { throw "Fallback ownership marker is invalid." }
            if (Test-NativeTreeHasReparsePoint $ExactFallback) { throw "Fallback cleanup tree contains a reparse point." }
            Remove-Item -LiteralPath $ExactFallback -Recurse -Force -ErrorAction Stop
            if (Test-Path -LiteralPath $ExactFallback) { throw "Fallback LocalState remained after cleanup." }
        } catch { $FinalErrors.Add("fallback root: $($_.Exception.Message)") }
    }
    if (-not $FallbackParentPreexisting -and (Test-Path -LiteralPath $FallbackParent)) {
        try {
            $ParentItem = Get-Item -LiteralPath $FallbackParent -Force
            if (($ParentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Fallback parent is a reparse point." }
            if (@(Get-ChildItem -LiteralPath $FallbackParent -Force -ErrorAction Stop).Count -eq 0) { Remove-Item -LiteralPath $FallbackParent -Force -ErrorAction Stop }
            if (Test-Path -LiteralPath $FallbackParent) { throw "Run-created fallback parent was not empty after cleanup." }
        } catch { $FinalErrors.Add("fallback parent: $($_.Exception.Message)") }
    }
    if ($CertificateImportAttempted) {
        try { & scripts\windows\remove-development-certificate.ps1 -Thumbprint $Certificate.Thumbprint -StoreLocations @("CurrentUser\TrustedPeople")
        } catch { $FinalErrors.Add("certificate: $($_.Exception.Message)") }
    }
    if ($TemporaryRoot) {
        try {
            $RunnerTemp = [IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd("\") + "\"
            $ExactTemporary = [IO.Path]::GetFullPath($TemporaryRoot)
            if (-not $ExactTemporary.StartsWith($RunnerTemp, [StringComparison]::OrdinalIgnoreCase)) { throw "Refusing to clean native QA files outside RUNNER_TEMP." }
            if (Test-Path -LiteralPath $ExactTemporary) {
                if (Test-NativeTreeHasReparsePoint $ExactTemporary) { throw "Native QA temporary tree contains a reparse point." }
                Remove-Item -LiteralPath $ExactTemporary -Recurse -Force -ErrorAction Stop
            }
            if (Test-Path -LiteralPath $ExactTemporary) { throw "Native QA temporary root remained after cleanup." }
        } catch { $FinalErrors.Add("temporary root: $($_.Exception.Message)") }
    }
    if ($FinalErrors.Count -ne 0) { throw "Native QA verification/cleanup failures: $($FinalErrors -join ' | ')" }
}

Write-Host "Native QA round $QaRound passed: same Store bytes, exact technical Publisher, LAI ZEYU visible authorship, nonce-bound API/DOM, installed paths, watchdog exit and clean uninstall."
