[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$EvidenceRoot,
    [Parameter(Mandatory = $true)][string]$OutputRoot
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "trusted-windows-sdk-tool.ps1")

function Assert-NativeSuccess([string]$Label) {
    if ($LASTEXITCODE -ne 0) { throw "$Label returned native exit code $LASTEXITCODE." }
}

function Assert-ExactJsonKeys([object]$Value, [string[]]$Expected, [string]$Label) {
    $Actual = @($Value.PSObject.Properties.Name | Sort-Object)
    $ExpectedSorted = @($Expected | Sort-Object)
    if (($Actual -join "|") -cne ($ExpectedSorted -join "|")) {
        throw "$Label does not have the exact approved schema."
    }
}

function Assert-SafeTree([string]$Root, [string]$Label) {
    $RootItem = Get-Item -LiteralPath $Root -Force
    $Entries = @(Get-ChildItem -LiteralPath $Root -Force -Recurse)
    if (($RootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        @($Entries | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 }).Count -ne 0) {
        throw "$Label contains a reparse point."
    }
}

if (-not $IsWindows) { throw "Partner Center upload staging requires Windows." }
if ([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) { throw "RUNNER_TEMP is required." }

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
Set-Location $ProjectRoot
$ExpectedProductId = "9NWTH4KJX5GW"
$ExpectedProduct = "Quant Scenario Studio by LAI ZEYU"
$ExpectedAuthor = "LAI ZEYU（来泽宇）"
$ExpectedIdentity = "LAIZEYU.QuantScenarioStudiobyLAIZEYU"
$ExpectedPublisher = "CN=A5F91D0A-30C6-48EE-944F-B767FA872BE8"
$ExpectedPackage = "QuantScenarioStudio_1.5.0.0_x64_store-unsigned.msix"
$SourceCommit = (& git rev-parse HEAD).Trim()
Assert-NativeSuccess "git rev-parse HEAD"
if ($SourceCommit -cnotmatch "^[0-9a-f]{40}$") { throw "A full source commit is required." }

$RunnerTemp = [IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd("\")
$RunnerPrefix = $RunnerTemp + "\"
$Evidence = (Resolve-Path -LiteralPath $EvidenceRoot).Path.TrimEnd("\")
$Output = [IO.Path]::GetFullPath($OutputRoot).TrimEnd("\")
if (-not $Evidence.StartsWith($RunnerPrefix, [StringComparison]::OrdinalIgnoreCase) -or
    [IO.Path]::GetFileName($Evidence) -cne "aegis-hosted-candidate-evidence") {
    throw "Hosted evidence must be the exact RUNNER_TEMP evidence leaf."
}
if (-not $Output.StartsWith($RunnerPrefix, [StringComparison]::OrdinalIgnoreCase) -or
    [IO.Path]::GetFileName($Output) -cne "aegis-partner-center-upload" -or
    (Test-Path -LiteralPath $Output)) {
    throw "Partner Center upload output must be a new exact RUNNER_TEMP leaf."
}
Assert-SafeTree $Evidence "Hosted evidence"

$ExpectedEvidenceFiles = @(
    "SHA256SUMS.txt", "candidate-evidence.json",
    "round-1-store-listing-about.png", "round-1-store-listing-home.png",
    "round-1-store-listing-privacy.png", "round-1-store-listing-scenarios.png",
    "round-2-store-listing-about.png", "round-2-store-listing-home.png",
    "round-2-store-listing-privacy.png", "round-2-store-listing-scenarios.png"
) | Sort-Object
$EvidenceFiles = @(Get-ChildItem -LiteralPath $Evidence -File -Force)
if ((($EvidenceFiles.Name | Sort-Object) -join "|") -cne ($ExpectedEvidenceFiles -join "|") -or
    @(Get-ChildItem -LiteralPath $Evidence -Directory -Force).Count -ne 0) {
    throw "Hosted evidence is not the exact ten-file allowlist."
}
Get-Content -LiteralPath (Join-Path $Evidence "SHA256SUMS.txt") | ForEach-Object {
    if ($_ -cnotmatch "^(?<hash>[0-9a-f]{64})  (?<name>[A-Za-z0-9.-]+)$") {
        throw "Hosted evidence checksum row is malformed."
    }
    $EvidenceFile = Join-Path $Evidence $Matches.name
    if (-not (Test-Path -LiteralPath $EvidenceFile -PathType Leaf) -or
        (Get-FileHash -Algorithm SHA256 -LiteralPath $EvidenceFile).Hash.ToLowerInvariant() -cne $Matches.hash) {
        throw "Hosted evidence checksum mismatch: $($Matches.name)"
    }
}

$EvidenceJsonPath = Join-Path $Evidence "candidate-evidence.json"
$HostedEvidence = Get-Content -Raw -LiteralPath $EvidenceJsonPath | ConvertFrom-Json
Assert-ExactJsonKeys $HostedEvidence @(
    "architecture", "author", "developmentCertificateUploaded", "generatedAt",
    "independentLaunchNonces", "nativeQaPasses", "packageIdentity", "packageVersion",
    "payloadFileCount", "payloadTreeSha256", "product", "publisherDisplayName", "qaRounds",
    "schemaVersion", "signedDevelopmentQaPackageFile", "signedDevelopmentQaPackageSha256",
    "signedDevelopmentQaPackageSize", "softwareBinariesUploaded", "sourceCommit",
    "technicalPublisher", "unsignedStorePackageFile", "unsignedStorePackageSha256",
    "unsignedStorePackageSize"
) "Hosted two-pass evidence"
if ([int]$HostedEvidence.schemaVersion -ne 1 -or $HostedEvidence.product -cne $ExpectedProduct -or
    $HostedEvidence.author -cne $ExpectedAuthor -or $HostedEvidence.publisherDisplayName -cne "LAI ZEYU" -or
    $HostedEvidence.packageIdentity -cne $ExpectedIdentity -or $HostedEvidence.technicalPublisher -cne $ExpectedPublisher -or
    $HostedEvidence.packageVersion -cne "1.5.0.0" -or $HostedEvidence.architecture -cne "x64" -or
    $HostedEvidence.sourceCommit -cne $SourceCommit -or $HostedEvidence.unsignedStorePackageFile -cne $ExpectedPackage -or
    [int]$HostedEvidence.nativeQaPasses -ne 2 -or [int]$HostedEvidence.independentLaunchNonces -ne 2 -or
    $HostedEvidence.softwareBinariesUploaded -or $HostedEvidence.developmentCertificateUploaded) {
    throw "Hosted two-pass evidence identity, source or upload boundary is invalid."
}
foreach ($Hash in @(
    [string]$HostedEvidence.unsignedStorePackageSha256,
    [string]$HostedEvidence.signedDevelopmentQaPackageSha256,
    [string]$HostedEvidence.payloadTreeSha256
)) {
    if ($Hash -cnotmatch "^[0-9a-f]{64}$") { throw "Hosted evidence contains an invalid lineage hash." }
}
$Rounds = @($HostedEvidence.qaRounds)
if ($Rounds.Count -ne 2 -or (@($Rounds.nonce | Sort-Object -Unique)).Count -ne 2) {
    throw "Hosted evidence does not contain two distinct launch nonces."
}
for ($Index = 0; $Index -lt 2; $Index++) {
    $Round = $Rounds[$Index]
    Assert-ExactJsonKeys $Round @(
        "apiHealthValidated", "coreDataValidated", "deterministicSyntheticScenarioValidated", "nonce",
        "packageAbsentAfterUninstall", "packageSha256After", "packageSha256Before", "payloadTreeSha256",
        "pfnAndLocalStateAbsentAfterUninstall", "qaRound", "screenshots", "shellForceKilled",
        "sidecarExitedViaParentWatchdog", "storeExecutionLocked", "submissionPackageSha256"
    ) "Hosted QA round $($Index + 1)"
    if ([int]$Round.qaRound -ne ($Index + 1) -or [string]$Round.nonce -cnotmatch "^[0-9a-f]{64}$" -or
        $Round.packageSha256Before -cne $HostedEvidence.signedDevelopmentQaPackageSha256 -or
        $Round.packageSha256After -cne $HostedEvidence.signedDevelopmentQaPackageSha256 -or
        $Round.submissionPackageSha256 -cne $HostedEvidence.unsignedStorePackageSha256 -or
        $Round.payloadTreeSha256 -cne $HostedEvidence.payloadTreeSha256 -or
        -not $Round.apiHealthValidated -or -not $Round.coreDataValidated -or
        -not $Round.deterministicSyntheticScenarioValidated -or -not $Round.storeExecutionLocked -or
        -not $Round.shellForceKilled -or -not $Round.sidecarExitedViaParentWatchdog -or
        -not $Round.packageAbsentAfterUninstall -or -not $Round.pfnAndLocalStateAbsentAfterUninstall) {
        throw "Hosted QA round $($Index + 1) is not an exact-byte lifecycle PASS."
    }
}

$CandidateRoot = Join-Path $ProjectRoot "artifacts\candidate"
$CandidatePath = Join-Path $CandidateRoot "candidate.json"
$Candidate = Get-Content -Raw -LiteralPath $CandidatePath | ConvertFrom-Json
$SubmissionPath = (Resolve-Path -LiteralPath (Join-Path $CandidateRoot $ExpectedPackage)).Path
if ($Candidate.packageIdentity -cne $ExpectedIdentity -or $Candidate.packagePublisher -cne $ExpectedPublisher -or
    $Candidate.sourceCommit -cne $SourceCommit -or $Candidate.submissionPackageFile -cne $ExpectedPackage -or
    $Candidate.submissionPackageSha256 -cne $HostedEvidence.unsignedStorePackageSha256 -or
    [long]$Candidate.submissionPackageSize -ne [long]$HostedEvidence.unsignedStorePackageSize -or
    $Candidate.payloadTreeSha256 -cne $HostedEvidence.payloadTreeSha256 -or
    (Get-FileHash -Algorithm SHA256 -LiteralPath $SubmissionPath).Hash.ToLowerInvariant() -cne $HostedEvidence.unsignedStorePackageSha256 -or
    (Get-Item -LiteralPath $SubmissionPath).Length -ne [long]$HostedEvidence.unsignedStorePackageSize) {
    throw "Unsigned submission no longer matches the twice-validated Store lineage."
}
$Signature = Get-AuthenticodeSignature -LiteralPath $SubmissionPath
if ($Signature.Status -ne [Management.Automation.SignatureStatus]::NotSigned -or $Signature.SignerCertificate) {
    throw "Partner Center submission must remain unsigned."
}

$WorkRoot = Join-Path $RunnerTemp ("aegis-store-sbom-$env:GITHUB_RUN_ID-$env:GITHUB_RUN_ATTEMPT")
if ([IO.Path]::GetFileName($WorkRoot) -cnotmatch "^aegis-store-sbom-[0-9]+-[0-9]+$" -or
    (Test-Path -LiteralPath $WorkRoot)) {
    throw "SBOM work root is not a new exact RUNNER_TEMP leaf."
}
New-Item -ItemType Directory -Path $Output | Out-Null
try {
    $PayloadRoot = Join-Path $WorkRoot "unsigned-msix-payload"
    New-Item -ItemType Directory -Path $PayloadRoot -Force | Out-Null
    $MakeAppx = Get-AegisTrustedWindowsSdkTool -Name "makeappx.exe"
    & $MakeAppx unpack /p $SubmissionPath /d $PayloadRoot /o | Out-Host
    Assert-NativeSuccess "unsigned Store MSIX unpack"
    Assert-SafeTree $PayloadRoot "Unsigned Store payload"

    [xml]$Manifest = Get-Content -Raw -LiteralPath (Join-Path $PayloadRoot "AppxManifest.xml")
    $Namespace = [Xml.XmlNamespaceManager]::new($Manifest.NameTable)
    $Namespace.AddNamespace("m", "http://schemas.microsoft.com/appx/manifest/foundation/windows10")
    $Identity = $Manifest.SelectSingleNode("/m:Package/m:Identity", $Namespace)
    $Properties = $Manifest.SelectSingleNode("/m:Package/m:Properties", $Namespace)
    $Languages = @($Manifest.SelectNodes("/m:Package/m:Resources/m:Resource", $Namespace) | ForEach-Object {
        ([string]$_.Language).ToLowerInvariant()
    })
    if ($Identity.Name -cne $ExpectedIdentity -or $Identity.Publisher -cne $ExpectedPublisher -or
        $Identity.Version -cne "1.5.0.0" -or $Identity.ProcessorArchitecture -cne "x64" -or
        $Properties.DisplayName -cne $ExpectedProduct -or $Properties.PublisherDisplayName -cne "LAI ZEYU" -or
        $Languages.Count -ne 1 -or $Languages[0] -cne "zh-cn" -or
        (Test-Path -LiteralPath (Join-Path $PayloadRoot "AppxSignature.p7x")) -or
        (Test-Path -LiteralPath (Join-Path $PayloadRoot "AppxMetadata\CodeIntegrity.cat"))) {
        throw "Unpacked unsigned Store manifest identity, language or signature boundary is invalid."
    }

    dotnet tool restore
    Assert-NativeSuccess "dotnet tool restore"
    dotnet sbom-tool generate `
        -b $PayloadRoot `
        -bc $ProjectRoot `
        -pn $ExpectedProduct `
        -pv "1.5.0" `
        -ps $ExpectedAuthor `
        -nsb "https://github.com/lzy2767865503-pixel/aegis-forecast"
    Assert-NativeSuccess "Microsoft SPDX SBOM generation"
    $ManifestRoot = Join-Path $PayloadRoot "_manifest"
    if (-not (Test-Path -LiteralPath $ManifestRoot -PathType Container)) {
        throw "Microsoft SPDX manifest root was not generated."
    }
    $SpdxFiles = @(Get-ChildItem -LiteralPath $ManifestRoot -File -Force -Recurse -Filter "manifest.spdx.json")
    if ($SpdxFiles.Count -ne 1) { throw "Expected one Microsoft SPDX manifest." }
    $Spdx = Get-Content -Raw -LiteralPath $SpdxFiles[0].FullName | ConvertFrom-Json
    if ($Spdx.spdxVersion -cne "SPDX-2.2" -or $Spdx.dataLicense -cne "CC0-1.0" -or
        @($Spdx.files).Count -lt 1 -or @($Spdx.packages).Count -lt 1) {
        throw "Microsoft SPDX manifest is incomplete."
    }

    $CopiedSubmission = Join-Path $Output $ExpectedPackage
    Copy-Item -LiteralPath $SubmissionPath -Destination $CopiedSubmission
    Copy-Item -LiteralPath $EvidenceJsonPath -Destination (Join-Path $Output "two-pass-lineage.json")
    Copy-Item -LiteralPath $ManifestRoot -Destination (Join-Path $Output "SBOM") -Recurse

    $ScreenshotRoot = Join-Path $Output "StoreScreenshots"
    New-Item -ItemType Directory -Path $ScreenshotRoot | Out-Null
    $ScreenshotMapping = @(
        [ordered]@{ source = "round-2-store-listing-home.png"; target = "01-Home.png"; view = "home" },
        [ordered]@{ source = "round-2-store-listing-scenarios.png"; target = "02-Scenarios.png"; view = "scenarios" },
        [ordered]@{ source = "round-2-store-listing-privacy.png"; target = "03-Privacy.png"; view = "privacy" },
        [ordered]@{ source = "round-2-store-listing-about.png"; target = "04-About.png"; view = "about" }
    )
    $ScreenshotLineage = [Collections.Generic.List[object]]::new()
    foreach ($Mapping in $ScreenshotMapping) {
        $RoundOne = @($Rounds[0].screenshots | Where-Object view -CEQ $Mapping.view)
        $RoundTwo = @($Rounds[1].screenshots | Where-Object view -CEQ $Mapping.view)
        if ($RoundOne.Count -ne 1 -or $RoundTwo.Count -ne 1 -or
            $RoundOne[0].sha256 -cne $RoundTwo[0].sha256 -or
            [int]$RoundTwo[0].width -ne 1600 -or [int]$RoundTwo[0].height -ne 900 -or
            -not $RoundOne[0].privacyValidated -or -not $RoundTwo[0].privacyValidated -or
            $RoundTwo[0].fileName -cne $Mapping.source) {
            throw "Store screenshot view $($Mapping.view) is not identical and privacy-validated across both rounds."
        }
        $SourceScreenshot = Join-Path $Evidence $Mapping.source
        $TargetScreenshot = Join-Path $ScreenshotRoot $Mapping.target
        Copy-Item -LiteralPath $SourceScreenshot -Destination $TargetScreenshot
        $ScreenshotHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $TargetScreenshot).Hash.ToLowerInvariant()
        if ($ScreenshotHash -cne $RoundTwo[0].sha256) { throw "Store screenshot copy changed: $($Mapping.view)" }
        $ScreenshotLineage.Add([ordered]@{
            file = "StoreScreenshots/$($Mapping.target)"
            view = $Mapping.view
            width = 1600
            height = 900
            sha256 = $ScreenshotHash
            validatedInBothRounds = $true
            privacyValidated = $true
        })
    }

    $SbomInventory = @(
        Get-ChildItem -LiteralPath (Join-Path $Output "SBOM") -File -Force -Recurse |
            Sort-Object FullName |
            ForEach-Object {
                [ordered]@{
                    file = [IO.Path]::GetRelativePath($Output, $_.FullName).Replace("\", "/")
                    size = [long]$_.Length
                    sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToLowerInvariant()
                }
            }
    )
    if ($SbomInventory.Count -lt 1) { throw "Partner Center upload bundle has no SPDX SBOM file." }

    $UploadLineage = [ordered]@{
        schemaVersion = 1
        productId = $ExpectedProductId
        product = $ExpectedProduct
        author = $ExpectedAuthor
        publisherDisplayName = "LAI ZEYU"
        technicalPublisher = $ExpectedPublisher
        packageIdentity = $ExpectedIdentity
        packageVersion = "1.5.0.0"
        architecture = "x64"
        sourceCommit = $SourceCommit
        submissionPackageFile = $ExpectedPackage
        submissionPackageSize = [long]$HostedEvidence.unsignedStorePackageSize
        submissionPackageSha256 = [string]$HostedEvidence.unsignedStorePackageSha256
        qaCandidatePackageSha256 = [string]$HostedEvidence.signedDevelopmentQaPackageSha256
        payloadFileCount = [int]$HostedEvidence.payloadFileCount
        payloadTreeSha256 = [string]$HostedEvidence.payloadTreeSha256
        staticValidationPasses = 2
        runtimeLifecyclePasses = 2
        independentLaunchNonces = @($Rounds.nonce)
        screenshots = @($ScreenshotLineage)
        sbom = $SbomInventory
        submissionSignatureStatus = "UNSIGNED_FOR_PARTNER_CENTER"
        submissionStatus = "NOT_SUBMITTED"
        certificationStatus = "NOT_CERTIFIED"
        githubRunId = [string]$env:GITHUB_RUN_ID
        githubRunAttempt = [string]$env:GITHUB_RUN_ATTEMPT
        generatedAt = [DateTimeOffset]::UtcNow.ToString("o")
    }
    $UploadLineagePath = Join-Path $Output "partner-center-upload.json"
    [IO.File]::WriteAllText(
        $UploadLineagePath,
        (($UploadLineage | ConvertTo-Json -Depth 8 -Compress) + "`n"),
        [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText(
        (Join-Path $Output "STORE-SUBMISSION-SHA256.txt"),
        "$($HostedEvidence.unsignedStorePackageSha256)  $ExpectedPackage`n",
        [Text.UTF8Encoding]::new($false))

    Assert-SafeTree $Output "Partner Center upload bundle"
    $BundleFiles = @(Get-ChildItem -LiteralPath $Output -File -Force -Recurse)
    if (@($BundleFiles | Where-Object Extension -CEQ ".msix").Count -ne 1 -or
        @($BundleFiles | Where-Object { $_.Extension -cnotin @(".msix", ".json", ".png", ".txt") }).Count -ne 0 -or
        @($BundleFiles | Where-Object { $_.Name -match "(?i)(signed-dev|\.cer$|\.pfx$)" }).Count -ne 0) {
        throw "Partner Center upload bundle contains an unapproved file type or development artifact."
    }
    $ChecksumRows = @(
        $BundleFiles |
            Sort-Object FullName |
            ForEach-Object {
                $Relative = [IO.Path]::GetRelativePath($Output, $_.FullName).Replace("\", "/")
                "$((Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToLowerInvariant())  $Relative"
            }
    )
    [IO.File]::WriteAllText(
        (Join-Path $Output "SHA256SUMS.txt"),
        (($ChecksumRows -join "`n") + "`n"),
        [Text.UTF8Encoding]::new($false))

    $CopiedSignature = Get-AuthenticodeSignature -LiteralPath $CopiedSubmission
    if ($CopiedSignature.Status -ne [Management.Automation.SignatureStatus]::NotSigned -or
        $CopiedSignature.SignerCertificate -or
        (Get-FileHash -Algorithm SHA256 -LiteralPath $CopiedSubmission).Hash.ToLowerInvariant() -cne $HostedEvidence.unsignedStorePackageSha256) {
        throw "Staged Partner Center MSIX is signed or changed."
    }
} finally {
    if (Test-Path -LiteralPath $WorkRoot) {
        $ExactWorkRoot = [IO.Path]::GetFullPath($WorkRoot).TrimEnd("\")
        if (-not $ExactWorkRoot.StartsWith($RunnerPrefix, [StringComparison]::OrdinalIgnoreCase) -or
            [IO.Path]::GetFileName($ExactWorkRoot) -cnotmatch "^aegis-store-sbom-[0-9]+-[0-9]+$") {
            throw "Refusing to clean an unbound SBOM work root."
        }
        Assert-SafeTree $ExactWorkRoot "SBOM work root"
        Remove-Item -LiteralPath $ExactWorkRoot -Recurse -Force
    }
}

Write-Host "Prepared one exact unsigned Partner Center MSIX, four twice-validated screenshots, SPDX SBOM, lineage and checksums."
