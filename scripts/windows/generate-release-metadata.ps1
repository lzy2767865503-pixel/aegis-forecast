[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "canonical-evidence-policy.ps1")

function Assert-NativeSuccess([string]$Label) {
    if ($LASTEXITCODE -ne 0) { throw "$Label returned native exit code $LASTEXITCODE." }
}

function Assert-ExactSchema {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string[]]$Allowed,
        [Parameter(Mandatory = $true)][string]$Label
    )
    $Actual = @($Value.PSObject.Properties.Name)
    $Missing = @($Allowed | Where-Object { $_ -notin $Actual })
    $Unknown = @($Actual | Where-Object { $_ -notin $Allowed })
    if ($Missing.Count -ne 0 -or $Unknown.Count -ne 0) {
        throw "$Label schema mismatch. Missing=[$($Missing -join ',')] Unknown=[$($Unknown -join ',')]"
    }
}

function Assert-Hash([string]$Value, [int]$Length, [string]$Label) {
    if ($Value -cnotmatch "^[0-9a-f]{$Length}$") { throw "$Label is not canonical lowercase hexadecimal." }
}

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
Set-Location $ProjectRoot
$ExpectedProduct = "Quant Scenario Studio by LAI ZEYU"
$ExpectedAuthor = "LAI ZEYU（来泽宇）"
$ExpectedStoreIdentityName = "LAIZEYU.QuantScenarioStudiobyLAIZEYU"
$ExpectedPublisher = "CN=A5F91D0A-30C6-48EE-944F-B767FA872BE8"
$CandidateRoot = Join-Path $ProjectRoot "artifacts\candidate"
$QaRoot = Join-Path $ProjectRoot "artifacts\qa"
$WackRoot = Join-Path $ProjectRoot "artifacts\wack"
$PrivateSummaryRoot = Join-Path $ProjectRoot "artifacts\private-summary"
foreach ($Required in @($CandidateRoot, $QaRoot, $WackRoot)) {
    if (-not (Test-Path -LiteralPath $Required)) { throw "Required private verification input is missing: $Required" }
}
if (Test-Path -LiteralPath $PrivateSummaryRoot) { throw "Private summary root must not preexist." }
New-Item -ItemType Directory -Path $PrivateSummaryRoot | Out-Null

$Candidate = Get-Content -Raw -LiteralPath (Join-Path $CandidateRoot "candidate.json") | ConvertFrom-Json
Assert-ExactSchema $Candidate @(
    "schemaVersion", "product", "author", "publisherDisplayName", "uiLanguage",
    "packageIdentity", "packagePublisher", "packageVersion", "architecture",
    "sourceCommit", "packageFile", "packageSize", "packageSha256",
    "submissionPackageFile", "submissionPackageSize", "submissionPackageSha256",
    "payloadFileCount", "payloadTreeSha256", "certificateFile",
    "certificateSha256", "certificateThumbprint", "certificateSubject",
    "developmentCertificateRole", "signedDevelopmentCandidate", "unsignedStoreSubmission"
) "candidate.json"
if ($Candidate.schemaVersion -ne 3 -or $Candidate.product -cne $ExpectedProduct -or
    $Candidate.author -cne $ExpectedAuthor -or $Candidate.publisherDisplayName -cne "LAI ZEYU" -or
    $Candidate.packagePublisher -cne $ExpectedPublisher -or $Candidate.certificateSubject -cne $ExpectedPublisher -or
    $Candidate.packageIdentity -cne $ExpectedStoreIdentityName -or
    $Candidate.developmentCertificateRole -cne "PartnerCenterTechnicalPublisherOnly" -or
    -not $Candidate.signedDevelopmentCandidate -or -not $Candidate.unsignedStoreSubmission) {
    throw "Candidate identity boundary is invalid."
}
Assert-Hash $Candidate.sourceCommit 40 "sourceCommit"
Assert-Hash $Candidate.packageSha256 64 "packageSha256"
Assert-Hash $Candidate.submissionPackageSha256 64 "submissionPackageSha256"
Assert-Hash $Candidate.payloadTreeSha256 64 "payloadTreeSha256"
Assert-Hash $Candidate.certificateSha256 64 "certificateSha256"
if ($Candidate.certificateThumbprint -cnotmatch "^[0-9A-F]{40}$") { throw "Certificate thumbprint is not canonical uppercase SHA-1." }

$PackagePath = Join-Path $CandidateRoot $Candidate.packageFile
$SubmissionPath = Join-Path $CandidateRoot $Candidate.submissionPackageFile
$CerPath = Join-Path $CandidateRoot $Candidate.certificateFile
if ((Get-FileHash -Algorithm SHA256 -LiteralPath $PackagePath).Hash.ToLowerInvariant() -cne $Candidate.packageSha256 -or
    (Get-Item -LiteralPath $PackagePath).Length -ne [long]$Candidate.packageSize) { throw "Candidate MSIX changed before canonical summary generation." }
if ((Get-FileHash -Algorithm SHA256 -LiteralPath $SubmissionPath).Hash.ToLowerInvariant() -cne $Candidate.submissionPackageSha256 -or
    (Get-Item -LiteralPath $SubmissionPath).Length -ne [long]$Candidate.submissionPackageSize) { throw "Unsigned Store submission changed before canonical summary generation." }
if ((Get-FileHash -Algorithm SHA256 -LiteralPath $CerPath).Hash.ToLowerInvariant() -cne $Candidate.certificateSha256) { throw "Candidate certificate changed before canonical summary generation." }
$Certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new($CerPath)
if ($Certificate.Thumbprint -cne $Candidate.certificateThumbprint -or $Certificate.Subject -cne $ExpectedPublisher) { throw "Candidate certificate does not match the technical Publisher schema." }
$Equivalence = & scripts\windows\msix-payload-equivalence.ps1 `
    -SubmissionMsixPath $SubmissionPath `
    -QaMsixPath $PackagePath `
    -ExpectedQaCertificateThumbprint $Candidate.certificateThumbprint
if ($Equivalence.payloadTreeSha256 -cne $Candidate.payloadTreeSha256 -or
    [int]$Equivalence.payloadFileCount -ne [int]$Candidate.payloadFileCount -or
    $Equivalence.submissionPackageSha256 -cne $Candidate.submissionPackageSha256 -or
    $Equivalence.qaPackageSha256 -cne $Candidate.packageSha256) { throw "Candidate submission/QA payload equivalence is invalid." }

& scripts\windows\backend-hashes.ps1 -Mode Verify

$QaSummaries = @()
for ($Round = 1; $Round -le 2; $Round++) {
    $Summary = Get-Content -Raw -LiteralPath (Join-Path $QaRoot "round-$Round\lifecycle-dom-api-uninstall.json") | ConvertFrom-Json
    Assert-ExactSchema $Summary @(
        "qaRound", "product", "author", "technicalPublisher", "readOnly", "privacy", "demo",
        "apiHealthValidated", "coreDataValidated", "domDataReady", "sourceCommit", "nonce",
        "packageSha256Before", "packageSha256After", "submissionPackageSha256", "payloadTreeSha256",
        "submissionPayloadEquivalent", "packageFamily", "dataRootBinding",
        "installLocation", "shellProcessId", "backendProcessId", "shellExecutablePath",
        "backendExecutablePath", "shellForceKilled", "sidecarExitedViaParentWatchdog",
        "packageAbsentAfterUninstall", "pfnAndLocalStateAbsentAfterUninstall",
        "fallbackLocalStateAbsentAfterUninstall", "markerBoundLocalStateValidated", "capturedAt"
    ) "QA round $Round lifecycle"
    if ([string]$Summary.qaRound -cne [string]$Round -or $Summary.product -cne $ExpectedProduct -or
        $Summary.author -cne $ExpectedAuthor -or $Summary.technicalPublisher -cne $ExpectedPublisher -or
        $Summary.sourceCommit -cne $Candidate.sourceCommit -or $Summary.packageSha256Before -cne $Candidate.packageSha256 -or
        $Summary.packageSha256After -cne $Candidate.packageSha256 -or
        $Summary.submissionPackageSha256 -cne $Candidate.submissionPackageSha256 -or
        $Summary.payloadTreeSha256 -cne $Candidate.payloadTreeSha256 -or -not $Summary.submissionPayloadEquivalent -or
        -not $Summary.readOnly -or
        -not $Summary.apiHealthValidated -or -not $Summary.coreDataValidated -or -not $Summary.domDataReady -or
        -not $Summary.shellForceKilled -or -not $Summary.sidecarExitedViaParentWatchdog -or
        -not $Summary.packageAbsentAfterUninstall -or -not $Summary.pfnAndLocalStateAbsentAfterUninstall -or
        -not $Summary.fallbackLocalStateAbsentAfterUninstall -or -not $Summary.markerBoundLocalStateValidated) {
        throw "QA round $Round does not prove unchanged bytes and a clean nonce-bound lifecycle."
    }
    Assert-Hash $Summary.nonce 64 "QA round $Round nonce"
    $Static = Get-Content -Raw -LiteralPath (Join-Path $QaRoot "round-$Round\static-package-validation.json") | ConvertFrom-Json
    Assert-ExactSchema $Static @(
        "qaRound", "packageSha256", "submissionPackageSha256", "payloadTreeSha256",
        "submissionPayloadEquivalent", "sourceCommit", "manifestIdentity", "packageSigner",
        "publisherDisplayName", "language", "exeProduct", "exeCompany", "exeCopyright",
        "exeProductVersion", "packagedLegal", "packagedBackendHashManifestVerified", "packagedConfigAllowlist",
        "boundarySelfCheckUsedIsolatedRoot", "fallbackLocalStateAbsent", "forbiddenConnectorModulesAbsent"
    ) "QA round $Round static"
    if ([string]$Static.qaRound -cne [string]$Round -or $Static.packageSha256 -cne $Candidate.packageSha256 -or
        $Static.submissionPackageSha256 -cne $Candidate.submissionPackageSha256 -or
        $Static.payloadTreeSha256 -cne $Candidate.payloadTreeSha256 -or -not $Static.submissionPayloadEquivalent -or
        $Static.sourceCommit -cne $Candidate.sourceCommit -or $Static.manifestIdentity -cne $Candidate.packageIdentity -or
        $Static.packageSigner -cne $ExpectedPublisher -or $Static.publisherDisplayName -cne "LAI ZEYU" -or
        -not $Static.packagedLegal -or -not $Static.packagedBackendHashManifestVerified -or -not $Static.boundarySelfCheckUsedIsolatedRoot -or
        -not $Static.fallbackLocalStateAbsent -or -not $Static.forbiddenConnectorModulesAbsent) {
        throw "QA round $Round static package schema is invalid."
    }
    $QaSummaries += $Summary
}
if ($QaSummaries[0].nonce -ceq $QaSummaries[1].nonce) { throw "QA rounds must use distinct launch nonces." }

$WackSummaries = @()
for ($Round = 1; $Round -le 2; $Round++) {
    $Wack = Get-Content -Raw -LiteralPath (Join-Path $WackRoot "round-$Round\wack-summary.json") | ConvertFrom-Json
    Assert-ExactSchema $Wack @(
        "schemaVersion", "wackRound", "product", "author", "technicalPublisher", "sourceCommit",
        "packageSha256Before", "packageSha256After", "submissionPackageSha256", "payloadTreeSha256",
        "submissionPayloadEquivalent", "appcertResetExitCode", "appcertTestExitCode",
        "appcertReset", "appcertTest", "partialRun", "wackPackageFullName", "wackInstallLocation", "report", "reportSha256",
        "powershellTranscriptSha256", "appcertConsoleSha256", "resultCount", "overallResults",
        "hardTimeoutEnforced", "interactiveSessionId", "elevatedAdministrator", "wackFileVersion",
        "noRuntimeResidue", "capturedAt"
    ) "WACK round $Round summary"
    if ($Wack.schemaVersion -ne 3 -or [string]$Wack.wackRound -cne [string]$Round -or
        $Wack.product -cne $ExpectedProduct -or $Wack.author -cne $ExpectedAuthor -or
        $Wack.technicalPublisher -cne $ExpectedPublisher -or $Wack.sourceCommit -cne $Candidate.sourceCommit -or
        $Wack.packageSha256Before -cne $Candidate.packageSha256 -or $Wack.packageSha256After -cne $Candidate.packageSha256 -or
        $Wack.submissionPackageSha256 -cne $Candidate.submissionPackageSha256 -or
        $Wack.payloadTreeSha256 -cne $Candidate.payloadTreeSha256 -or -not $Wack.submissionPayloadEquivalent -or
        $Wack.appcertResetExitCode -ne 0 -or $Wack.appcertTestExitCode -ne 0 -or
        $Wack.appcertReset -cne "PASS" -or $Wack.appcertTest -cne "PASS" -or $Wack.partialRun -or
        -not $Wack.hardTimeoutEnforced -or [int]$Wack.interactiveSessionId -eq 0 -or
        -not $Wack.elevatedAdministrator -or [string]$Wack.wackFileVersion -cnotmatch '^\d+\.\d+\.\d+\.\d+$' -or
        [string]$Wack.wackFileVersion -cne [string]$env:AEGIS_APPROVED_WACK_FILE_VERSION -or -not $Wack.noRuntimeResidue) {
        throw "WACK round $Round summary does not prove a fresh, bounded, complete PASS on the common candidate lineage."
    }
    if ($Wack.wackPackageFullName -cnotmatch "^$([regex]::Escape($Candidate.packageIdentity))_" -or
        [IO.Path]::GetFileName([IO.Path]::GetFullPath([string]$Wack.wackInstallLocation).TrimEnd("\")) -cne $Wack.wackPackageFullName) {
        throw "WACK round $Round is not bound to the tested PackageFullName/install location."
    }
    $WackResults = @($Wack.overallResults)
    if ($WackResults.Count -lt 2 -or [int]$Wack.resultCount -ne $WackResults.Count -or @($WackResults | Where-Object { $_ -cne "PASS" }).Count -ne 0) {
        throw "WACK round $Round contains a missing, skipped, warning, not-run or failed result."
    }
    foreach ($HashField in @("reportSha256", "powershellTranscriptSha256", "appcertConsoleSha256")) { Assert-Hash ([string]$Wack.$HashField) 64 "WACK round $Round $HashField" }
    $WackSummaries += $Wack
}

dotnet tool restore
Assert-NativeSuccess "dotnet tool restore"
$ManifestRoot = Join-Path $ProjectRoot "artifacts\_manifest"
if (Test-Path -LiteralPath $ManifestRoot) { throw "Private SBOM manifest root must not preexist." }
dotnet sbom-tool generate -b (Join-Path $ProjectRoot "artifacts") -bc $ProjectRoot -pn $ExpectedProduct -pv "1.5.0" -ps $ExpectedAuthor -nsb "https://github.com/lzy2767865503-pixel/aegis-forecast"
Assert-NativeSuccess "Microsoft SPDX SBOM generation"
if (-not (Test-Path -LiteralPath $ManifestRoot)) { throw "Private SBOM generation failed." }

$Canonical = [ordered]@{
    schemaVersion = 3
    product = $ExpectedProduct
    author = $ExpectedAuthor
    publisherDisplayName = "LAI ZEYU"
    technicalPublisher = $ExpectedPublisher
    storeIdentityName = $Candidate.packageIdentity
    sourceCommit = $Candidate.sourceCommit
    submissionPackageSha256 = $Candidate.submissionPackageSha256
    qaCandidatePackageSha256 = $Candidate.packageSha256
    payloadTreeSha256 = $Candidate.payloadTreeSha256
    qa1PackageSha256 = $QaSummaries[0].packageSha256After
    qa2PackageSha256 = $QaSummaries[1].packageSha256After
    wack1PackageSha256 = $WackSummaries[0].packageSha256After
    wack2PackageSha256 = $WackSummaries[1].packageSha256After
    wack1ReportSha256 = $WackSummaries[0].reportSha256
    wack2ReportSha256 = $WackSummaries[1].reportSha256
    qaRounds = @("PASS", "PASS")
    wackRounds = @("PASS", "PASS")
    binariesPublished = $false
    storeHandoffPrivate = $true
}
$CanonicalPath = Join-Path $PrivateSummaryRoot "canonical-verification.json"
$CanonicalText = $Canonical | ConvertTo-Json -Depth 4 -Compress
[IO.File]::WriteAllText($CanonicalPath, $CanonicalText + "`n", [Text.UTF8Encoding]::new($false))
Assert-AegisCanonicalEvidenceFile $CanonicalPath

if ($env:GITHUB_STEP_SUMMARY) {
    @(
        "## Quant Scenario Studio Windows Store verification",
        "",
        "- Visible author: LAI ZEYU（来泽宇）",
        "- PublisherDisplayName: LAI ZEYU",
        "- Partner Center Store ID: ``9NWTH4KJX5GW``",
        "- Production Identity Name: ``$ExpectedStoreIdentityName``",
        "- Partner Center technical Publisher: validated",
        "- Unsigned Partner Center submission SHA-256: ``$($Candidate.submissionPackageSha256)``",
        "- Temporary QA copy SHA-256: ``$($Candidate.packageSha256)``",
        "- Exact common payload tree SHA-256: ``$($Candidate.payloadTreeSha256)``",
        "- Native lifecycle QA: PASS twice with distinct nonces",
        "- WACK: complete PASS twice in elevated active session on approved AppCert $($WackSummaries[0].wackFileVersion), with hard timeout",
        "- Store handoff: unsigned original is eligible only for local fixed-NTFS exact-ACL retention; no Store package is uploaded to GitHub"
    ) | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Encoding utf8
}

Write-Host "Validated strict private schemas and wrote a fixed job summary for local exact-ACL unsigned Store handoff retention."
