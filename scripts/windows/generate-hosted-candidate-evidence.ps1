[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$OutputRoot
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true
Set-StrictMode -Version Latest

function Assert-CanonicalHash([string]$Value, [int]$Length, [string]$Label) {
    if ($Value -cnotmatch "^[0-9a-f]{$Length}$") {
        throw "$Label is not canonical lowercase hexadecimal."
    }
}

function Assert-ExactKeys($Value, [string[]]$Expected, [string]$Label) {
    $Actual = @($Value.PSObject.Properties.Name | Sort-Object)
    $CanonicalExpected = @($Expected | Sort-Object)
    if (($Actual -join '|') -cne ($CanonicalExpected -join '|')) {
        throw "$Label schema differs from the exact candidate-evidence contract."
    }
}

function Assert-FileHash([string]$Path, [string]$ExpectedHash, [long]$ExpectedSize, [string]$Label) {
    $Item = Get-Item -LiteralPath $Path -Force
    if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        [long]$Item.Length -ne $ExpectedSize -or
        (Get-FileHash -Algorithm SHA256 -LiteralPath $Item.FullName).Hash.ToLowerInvariant() -cne $ExpectedHash) {
        throw "$Label bytes differ from their frozen lineage."
    }
}

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
Set-Location $ProjectRoot
$CandidateRoot = Join-Path $ProjectRoot "artifacts\candidate"
$QaRoot = Join-Path $ProjectRoot "artifacts\qa"
$CandidatePath = Join-Path $CandidateRoot "candidate.json"
if (-not (Test-Path -LiteralPath $CandidatePath -PathType Leaf)) {
    throw "Hosted Windows candidate.json is missing."
}

$Candidate = Get-Content -Raw -LiteralPath $CandidatePath | ConvertFrom-Json
Assert-ExactKeys $Candidate @(
    "schemaVersion", "product", "author", "publisherDisplayName", "uiLanguage",
    "packageIdentity", "packagePublisher", "packageVersion", "architecture",
    "sourceCommit", "packageFile", "packageSize", "packageSha256",
    "submissionPackageFile", "submissionPackageSize", "submissionPackageSha256",
    "payloadFileCount", "payloadTreeSha256", "certificateFile",
    "certificateSha256", "certificateThumbprint", "certificateSubject",
    "developmentCertificateRole", "signedDevelopmentCandidate", "unsignedStoreSubmission"
) "candidate.json"

$ExpectedProduct = "Quant Scenario Studio by LAI ZEYU"
$ExpectedAuthor = "LAI ZEYU（来泽宇）"
$ExpectedIdentity = "LAIZEYU.QuantScenarioStudiobyLAIZEYU"
$ExpectedPublisher = "CN=A5F91D0A-30C6-48EE-944F-B767FA872BE8"
if ($Candidate.schemaVersion -ne 3 -or
    $Candidate.product -cne $ExpectedProduct -or
    $Candidate.author -cne $ExpectedAuthor -or
    $Candidate.publisherDisplayName -cne "LAI ZEYU" -or
    $Candidate.packageIdentity -cne $ExpectedIdentity -or
    $Candidate.packagePublisher -cne $ExpectedPublisher -or
    $Candidate.certificateSubject -cne $ExpectedPublisher -or
    $Candidate.packageVersion -cne "1.5.0.0" -or
    $Candidate.architecture -cne "x64" -or
    $Candidate.developmentCertificateRole -cne "PartnerCenterTechnicalPublisherOnly" -or
    -not $Candidate.signedDevelopmentCandidate -or -not $Candidate.unsignedStoreSubmission) {
    throw "Hosted Windows candidate identity/signing boundary is invalid."
}
foreach ($HashField in @("packageSha256", "submissionPackageSha256", "payloadTreeSha256", "certificateSha256")) {
    Assert-CanonicalHash ([string]$Candidate.$HashField) 64 "candidate $HashField"
}
Assert-CanonicalHash ([string]$Candidate.sourceCommit) 40 "candidate sourceCommit"
if ([string]$Candidate.certificateThumbprint -cnotmatch '^[0-9A-F]{40}$') {
    throw "Candidate development-certificate thumbprint is malformed."
}
$CurrentCommit = (& git rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $CurrentCommit -cne $Candidate.sourceCommit) {
    throw "Hosted Windows candidate was not built from the checked-out source commit."
}

$SignedQaPath = Join-Path $CandidateRoot ([string]$Candidate.packageFile)
$UnsignedStorePath = Join-Path $CandidateRoot ([string]$Candidate.submissionPackageFile)
$CertificatePath = Join-Path $CandidateRoot ([string]$Candidate.certificateFile)
Assert-FileHash $SignedQaPath ([string]$Candidate.packageSha256) ([long]$Candidate.packageSize) "signed QA MSIX"
Assert-FileHash $UnsignedStorePath ([string]$Candidate.submissionPackageSha256) ([long]$Candidate.submissionPackageSize) "unsigned Store MSIX"
Assert-FileHash $CertificatePath ([string]$Candidate.certificateSha256) ((Get-Item -LiteralPath $CertificatePath).Length) "development CER"

$ExpectedScreenshots = @(
    [ordered]@{ fileName = 'store-listing-home.png'; view = 'home'; heading = 'Nasdaq-100 说明性合成情景' },
    [ordered]@{ fileName = 'store-listing-scenarios.png'; view = 'scenarios'; heading = 'Nasdaq-100 研究排名' },
    [ordered]@{ fileName = 'store-listing-privacy.png'; view = 'privacy'; heading = '隐私与本地数据' },
    [ordered]@{ fileName = 'store-listing-about.png'; view = 'about'; heading = '关于 Quant Scenario Studio' }
)
$RoundEvidence = [Collections.Generic.List[object]]::new()
$ObservedNonces = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)

$ExactOutput = [IO.Path]::GetFullPath($OutputRoot).TrimEnd('\')
$RunnerTempPrefix = if ($env:RUNNER_TEMP) {
    [IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\') + '\'
} else {
    ''
}
if ([string]::IsNullOrWhiteSpace($ExactOutput) -or
    [string]::IsNullOrWhiteSpace($RunnerTempPrefix) -or
    -not $ExactOutput.StartsWith($RunnerTempPrefix, [StringComparison]::OrdinalIgnoreCase) -or
    [IO.Path]::GetFileName($ExactOutput) -cne 'aegis-hosted-candidate-evidence') {
    throw "Evidence output must be the exact aegis-hosted-candidate-evidence leaf."
}
if (Test-Path -LiteralPath $ExactOutput) {
    throw "Hosted candidate evidence output must not preexist."
}
New-Item -ItemType Directory -Path $ExactOutput | Out-Null

for ($Round = 1; $Round -le 2; $Round++) {
    $RoundRoot = Join-Path $QaRoot "round-$Round"
    $LifecyclePath = Join-Path $RoundRoot "lifecycle-dom-api-uninstall.json"
    $StaticPath = Join-Path $RoundRoot "static-package-validation.json"
    $Lifecycle = Get-Content -Raw -LiteralPath $LifecyclePath | ConvertFrom-Json
    $Static = Get-Content -Raw -LiteralPath $StaticPath | ConvertFrom-Json
    if ([string]$Lifecycle.qaRound -cne [string]$Round -or
        $Lifecycle.product -cne $ExpectedProduct -or $Lifecycle.author -cne $ExpectedAuthor -or
        $Lifecycle.technicalPublisher -cne $ExpectedPublisher -or
        $Lifecycle.sourceCommit -cne $Candidate.sourceCommit -or
        $Lifecycle.packageSha256Before -cne $Candidate.packageSha256 -or
        $Lifecycle.packageSha256After -cne $Candidate.packageSha256 -or
        $Lifecycle.submissionPackageSha256 -cne $Candidate.submissionPackageSha256 -or
        $Lifecycle.payloadTreeSha256 -cne $Candidate.payloadTreeSha256 -or
        -not $Lifecycle.submissionPayloadEquivalent -or -not $Lifecycle.readOnly -or
        -not $Lifecycle.apiHealthValidated -or -not $Lifecycle.coreDataValidated -or -not $Lifecycle.domDataReady -or
        -not $Lifecycle.shellForceKilled -or -not $Lifecycle.sidecarExitedViaParentWatchdog -or
        -not $Lifecycle.packageAbsentAfterUninstall -or -not $Lifecycle.pfnAndLocalStateAbsentAfterUninstall -or
        -not $Lifecycle.fallbackLocalStateAbsentAfterUninstall -or -not $Lifecycle.markerBoundLocalStateValidated -or
        [int]$Lifecycle.storeListingScreenshotCount -ne 4 -or @($Lifecycle.storeListingScreenshots).Count -ne 4) {
        throw "Hosted native QA round $Round did not prove the complete unchanged-byte lifecycle."
    }
    Assert-CanonicalHash ([string]$Lifecycle.nonce) 64 "round $Round nonce"
    if (-not $ObservedNonces.Add([string]$Lifecycle.nonce)) {
        throw "Hosted native QA rounds reused a launch nonce."
    }
    if ([string]$Static.qaRound -cne [string]$Round -or
        $Static.packageSha256 -cne $Candidate.packageSha256 -or
        $Static.submissionPackageSha256 -cne $Candidate.submissionPackageSha256 -or
        $Static.payloadTreeSha256 -cne $Candidate.payloadTreeSha256 -or
        -not $Static.submissionPayloadEquivalent -or $Static.sourceCommit -cne $Candidate.sourceCommit -or
        $Static.manifestIdentity -cne $ExpectedIdentity -or $Static.packageSigner -cne $ExpectedPublisher -or
        $Static.publisherDisplayName -cne 'LAI ZEYU' -or -not $Static.packagedLegal -or
        -not $Static.packagedBackendHashManifestVerified -or -not $Static.boundarySelfCheckUsedIsolatedRoot -or
        -not $Static.fallbackLocalStateAbsent -or -not $Static.forbiddenConnectorModulesAbsent) {
        throw "Hosted static package QA round $Round did not prove the exact Store boundary."
    }

    $ScreenshotEvidence = [Collections.Generic.List[object]]::new()
    $SeenScreenshotHashes = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    for ($Index = 0; $Index -lt $ExpectedScreenshots.Count; $Index++) {
        $Expected = $ExpectedScreenshots[$Index]
        $Observed = @($Lifecycle.storeListingScreenshots)[$Index]
        if ([string]$Observed.fileName -cne [string]$Expected.fileName -or
            [string]$Observed.view -cne [string]$Expected.view -or
            [string]$Observed.heading -cne [string]$Expected.heading -or
            [string]$Observed.sha256 -cnotmatch '^[0-9a-f]{64}$' -or
            -not $Observed.privacyValidated -or -not $SeenScreenshotHashes.Add([string]$Observed.sha256) -or
            [int]$Observed.width -lt 1366 -or [int]$Observed.width -gt 4096 -or
            [int]$Observed.height -lt 768 -or [int]$Observed.height -gt 2160) {
            throw "Hosted native QA round $Round screenshot $Index is malformed or duplicated."
        }
        $SourceScreenshot = Join-Path $RoundRoot ([string]$Observed.fileName)
        Assert-FileHash $SourceScreenshot ([string]$Observed.sha256) ((Get-Item -LiteralPath $SourceScreenshot).Length) "round $Round screenshot $Index"
        $PublicName = "round-$Round-$([string]$Observed.fileName)"
        $PublicPath = Join-Path $ExactOutput $PublicName
        Copy-Item -LiteralPath $SourceScreenshot -Destination $PublicPath
        Assert-FileHash $PublicPath ([string]$Observed.sha256) ((Get-Item -LiteralPath $SourceScreenshot).Length) "public evidence screenshot $PublicName"
        $ScreenshotEvidence.Add([ordered]@{
            fileName = $PublicName
            view = [string]$Observed.view
            heading = [string]$Observed.heading
            sha256 = [string]$Observed.sha256
            width = [int]$Observed.width
            height = [int]$Observed.height
            privacyValidated = $true
        })
    }

    $RoundEvidence.Add([ordered]@{
        qaRound = $Round
        nonce = [string]$Lifecycle.nonce
        packageSha256Before = [string]$Lifecycle.packageSha256Before
        packageSha256After = [string]$Lifecycle.packageSha256After
        submissionPackageSha256 = [string]$Lifecycle.submissionPackageSha256
        payloadTreeSha256 = [string]$Lifecycle.payloadTreeSha256
        apiHealthValidated = $true
        coreDataValidated = $true
        deterministicSyntheticScenarioValidated = $true
        storeExecutionLocked = $true
        shellForceKilled = $true
        sidecarExitedViaParentWatchdog = $true
        packageAbsentAfterUninstall = $true
        pfnAndLocalStateAbsentAfterUninstall = $true
        screenshots = @($ScreenshotEvidence)
    })
}

$Evidence = [ordered]@{
    schemaVersion = 1
    product = $ExpectedProduct
    author = $ExpectedAuthor
    publisherDisplayName = 'LAI ZEYU'
    sourceCommit = [string]$Candidate.sourceCommit
    packageIdentity = $ExpectedIdentity
    technicalPublisher = $ExpectedPublisher
    packageVersion = [string]$Candidate.packageVersion
    architecture = 'x64'
    unsignedStorePackageFile = [string]$Candidate.submissionPackageFile
    unsignedStorePackageSize = [long]$Candidate.submissionPackageSize
    unsignedStorePackageSha256 = [string]$Candidate.submissionPackageSha256
    signedDevelopmentQaPackageFile = [string]$Candidate.packageFile
    signedDevelopmentQaPackageSize = [long]$Candidate.packageSize
    signedDevelopmentQaPackageSha256 = [string]$Candidate.packageSha256
    payloadFileCount = [int]$Candidate.payloadFileCount
    payloadTreeSha256 = [string]$Candidate.payloadTreeSha256
    nativeQaPasses = 2
    independentLaunchNonces = 2
    qaRounds = @($RoundEvidence)
    softwareBinariesUploaded = $false
    developmentCertificateUploaded = $false
    generatedAt = [DateTimeOffset]::UtcNow.ToString('o')
}
$EvidencePath = Join-Path $ExactOutput 'candidate-evidence.json'
[IO.File]::WriteAllText(
    $EvidencePath,
    (($Evidence | ConvertTo-Json -Depth 8 -Compress) + "`n"),
    [Text.UTF8Encoding]::new($false)
)

$PublicFiles = @(Get-ChildItem -LiteralPath $ExactOutput -File -Force | Sort-Object Name)
if ($PublicFiles.Count -ne 9 -or
    @($PublicFiles | Where-Object { $_.Extension -cnotin @('.json', '.png') }).Count -ne 0 -or
    @($PublicFiles | Where-Object { $_.Extension -cin @('.msix', '.appx', '.exe', '.dll', '.pfx', '.cer', '.zip') }).Count -ne 0) {
    throw "Hosted candidate public evidence contains a software binary or an unexpected file."
}
$ChecksumRows = @($PublicFiles | ForEach-Object {
    "$((Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToLowerInvariant())  $($_.Name)"
})
[IO.File]::WriteAllLines(
    (Join-Path $ExactOutput 'SHA256SUMS.txt'),
    $ChecksumRows,
    [Text.UTF8Encoding]::new($false)
)

if ($env:GITHUB_STEP_SUMMARY) {
    @(
        '## Aegis hosted Windows candidate verification',
        '',
        "- Product: $ExpectedProduct",
        "- Author: $ExpectedAuthor",
        "- Source commit: ``$($Candidate.sourceCommit)``",
        "- Unsigned Partner Center MSIX SHA-256: ``$($Candidate.submissionPackageSha256)``",
        "- Signed development QA-copy SHA-256: ``$($Candidate.packageSha256)``",
        "- Common payload-tree SHA-256: ``$($Candidate.payloadTreeSha256)``",
        '- Native install/start/API/screenshot/watchdog/uninstall QA: PASS twice with distinct nonces',
        '- Public software binaries: none (only JSON, PNG and SHA-256 evidence may leave the hosted runner)'
    ) | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Encoding utf8
}

Write-Host "Hosted Windows candidate evidence passed: two complete unchanged-byte native QA rounds; no software binary entered public evidence."
