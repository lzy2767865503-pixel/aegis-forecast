[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "canonical-evidence-policy.ps1")

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

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
Set-Location $ProjectRoot
$CandidateRoot = Join-Path $ProjectRoot "artifacts\candidate"
$SummaryPath = Join-Path $ProjectRoot "artifacts\private-summary\canonical-verification.json"
$HandoffRoot = Join-Path $ProjectRoot "artifacts\store-handoff"
if (Test-Path -LiteralPath $HandoffRoot) { throw "Store handoff root must not preexist." }
if (-not (Test-Path -LiteralPath $SummaryPath -PathType Leaf)) { throw "Canonical verification evidence is missing." }
Assert-AegisCanonicalEvidenceFile $SummaryPath

$CandidatePath = Join-Path $CandidateRoot "candidate.json"
$Candidate = Get-Content -Raw -LiteralPath $CandidatePath | ConvertFrom-Json
Assert-ExactSchema $Candidate @(
    "schemaVersion", "product", "author", "publisherDisplayName", "uiLanguage",
    "packageIdentity", "packagePublisher", "packageVersion", "architecture",
    "sourceCommit", "packageFile", "packageSize", "packageSha256",
    "submissionPackageFile", "submissionPackageSize", "submissionPackageSha256",
    "payloadFileCount", "payloadTreeSha256", "certificateFile",
    "certificateSha256", "certificateThumbprint", "certificateSubject",
    "developmentCertificateRole", "signedDevelopmentCandidate", "unsignedStoreSubmission"
) "candidate.json"
if ($Candidate.schemaVersion -ne 3 -or $Candidate.product -cne "Quant Scenario Studio by LAI ZEYU" -or
    $Candidate.author -cne "LAI ZEYU（来泽宇）" -or $Candidate.publisherDisplayName -cne "LAI ZEYU" -or
    $Candidate.packageIdentity -cne "LAIZEYU.QuantScenarioStudiobyLAIZEYU" -or
    $Candidate.packagePublisher -cne "CN=A5F91D0A-30C6-48EE-944F-B767FA872BE8" -or
    $Candidate.developmentCertificateRole -cne "PartnerCenterTechnicalPublisherOnly" -or
    -not $Candidate.signedDevelopmentCandidate -or -not $Candidate.unsignedStoreSubmission) {
    throw "The Store handoff candidate identity or signed/unsigned separation is invalid."
}
if ([string]$Candidate.sourceCommit -cnotmatch "^[0-9a-f]{40}$" -or
    [string]$Candidate.submissionPackageSha256 -cnotmatch "^[0-9a-f]{64}$" -or
    [string]$Candidate.packageSha256 -cnotmatch "^[0-9a-f]{64}$" -or
    [string]$Candidate.payloadTreeSha256 -cnotmatch "^[0-9a-f]{64}$") {
    throw "Store handoff lineage hashes are invalid."
}
foreach ($Name in @([string]$Candidate.packageFile, [string]$Candidate.submissionPackageFile, [string]$Candidate.certificateFile)) {
    if ([IO.Path]::GetFileName($Name) -cne $Name) { throw "Candidate contains a non-basename private file reference." }
}
$HeadCommit = (& git rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $HeadCommit -cne $Candidate.sourceCommit) { throw "Store handoff source commit is not the exact checked-out commit." }

$SubmissionPath = (Resolve-Path -LiteralPath (Join-Path $CandidateRoot $Candidate.submissionPackageFile)).Path
$QaPath = (Resolve-Path -LiteralPath (Join-Path $CandidateRoot $Candidate.packageFile)).Path
if ((Get-FileHash -Algorithm SHA256 -LiteralPath $SubmissionPath).Hash.ToLowerInvariant() -cne $Candidate.submissionPackageSha256 -or
    (Get-Item -LiteralPath $SubmissionPath).Length -ne [long]$Candidate.submissionPackageSize) {
    throw "Unsigned Partner Center submission bytes changed before private handoff."
}
if ((Get-FileHash -Algorithm SHA256 -LiteralPath $QaPath).Hash.ToLowerInvariant() -cne $Candidate.packageSha256 -or
    (Get-Item -LiteralPath $QaPath).Length -ne [long]$Candidate.packageSize) {
    throw "Temporary QA copy bytes changed before private handoff."
}
$Equivalence = & scripts\windows\msix-payload-equivalence.ps1 `
    -SubmissionMsixPath $SubmissionPath `
    -QaMsixPath $QaPath `
    -ExpectedQaCertificateThumbprint $Candidate.certificateThumbprint
if ($Equivalence.submissionPackageSha256 -cne $Candidate.submissionPackageSha256 -or
    $Equivalence.qaPackageSha256 -cne $Candidate.packageSha256 -or
    $Equivalence.payloadTreeSha256 -cne $Candidate.payloadTreeSha256 -or
    [int]$Equivalence.payloadFileCount -ne [int]$Candidate.payloadFileCount) {
    throw "Unsigned submission and temporary QA copy do not retain the exact common payload tree."
}
$UnsignedSignature = Get-AuthenticodeSignature -LiteralPath $SubmissionPath
if ($UnsignedSignature.Status -ne [System.Management.Automation.SignatureStatus]::NotSigned -or $null -ne $UnsignedSignature.SignerCertificate) {
    throw "Partner Center handoff package must remain unsigned."
}

$Canonical = Get-Content -Raw -LiteralPath $SummaryPath | ConvertFrom-Json
if ($Canonical.sourceCommit -cne $Candidate.sourceCommit -or
    $Canonical.submissionPackageSha256 -cne $Candidate.submissionPackageSha256 -or
    $Canonical.qaCandidatePackageSha256 -cne $Candidate.packageSha256 -or
    $Canonical.payloadTreeSha256 -cne $Candidate.payloadTreeSha256 -or
    $Canonical.qa1PackageSha256 -cne $Candidate.packageSha256 -or
    $Canonical.qa2PackageSha256 -cne $Candidate.packageSha256 -or
    $Canonical.wack1PackageSha256 -cne $Candidate.packageSha256 -or
    $Canonical.wack2PackageSha256 -cne $Candidate.packageSha256 -or
    $Canonical.binariesPublished -or -not $Canonical.storeHandoffPrivate) {
    throw "Canonical evidence is not bound to one unsigned submission and the one twice-QA/twice-WACK temporary copy."
}

New-Item -ItemType Directory -Path $HandoffRoot | Out-Null
$HandoffPackage = Join-Path $HandoffRoot $Candidate.submissionPackageFile
Copy-Item -LiteralPath $SubmissionPath -Destination $HandoffPackage
if ((Get-FileHash -Algorithm SHA256 -LiteralPath $HandoffPackage).Hash.ToLowerInvariant() -cne $Candidate.submissionPackageSha256 -or
    (Get-Item -LiteralPath $HandoffPackage).Length -ne [long]$Candidate.submissionPackageSize) {
    throw "Private handoff copy differs from the verified unsigned submission."
}

$ChecksumName = "STORE-SUBMISSION-SHA256.txt"
$ChecksumText = "$($Candidate.submissionPackageSha256)  $($Candidate.submissionPackageFile)`n"
[IO.File]::WriteAllText((Join-Path $HandoffRoot $ChecksumName), $ChecksumText, [Text.UTF8Encoding]::new($false))
$Lineage = [ordered]@{
    schemaVersion = 1
    product = "Quant Scenario Studio by LAI ZEYU"
    author = "LAI ZEYU（来泽宇）"
    publisherDisplayName = "LAI ZEYU"
    partnerCenterProductId = "9NWTH4KJX5GW"
    packageIdentity = "LAIZEYU.QuantScenarioStudiobyLAIZEYU"
    technicalPublisher = "CN=A5F91D0A-30C6-48EE-944F-B767FA872BE8"
    sourceCommit = $Candidate.sourceCommit
    submissionPackageFile = $Candidate.submissionPackageFile
    submissionPackageSize = [long]$Candidate.submissionPackageSize
    submissionPackageSha256 = $Candidate.submissionPackageSha256
    qaCandidatePackageSha256 = $Candidate.packageSha256
    payloadFileCount = [int]$Candidate.payloadFileCount
    payloadTreeSha256 = $Candidate.payloadTreeSha256
    nativeQaRounds = 2
    wackRounds = 2
    submissionSignatureStatus = "UNSIGNED_FOR_PARTNER_CENTER"
    submissionStatus = "NOT_SUBMITTED"
    certificationStatus = "NOT_CERTIFIED"
    storeSignsAfterSubmission = $true
    qaCertificateIncluded = $false
    publicGitHubAsset = $false
    handoffVisibility = "LOCAL_FIXED_NTFS_EXACT_ACL_PENDING_RETENTION"
}
$LineagePath = Join-Path $HandoffRoot "store-submission-lineage.json"
[IO.File]::WriteAllText($LineagePath, (($Lineage | ConvertTo-Json -Depth 4 -Compress) + "`n"), [Text.UTF8Encoding]::new($false))

$HandoffFiles = @(Get-ChildItem -LiteralPath $HandoffRoot -File | ForEach-Object Name | Sort-Object)
$ExpectedFiles = @($Candidate.submissionPackageFile, $ChecksumName, "store-submission-lineage.json") | Sort-Object
if (($HandoffFiles -join "|") -cne ($ExpectedFiles -join "|")) { throw "Private Store handoff contains a non-allowlisted file." }
if (@(Get-ChildItem -LiteralPath $HandoffRoot -Directory -Force).Count -ne 0) { throw "Private Store handoff contains a directory." }

Write-Host "Prepared one protected private unsigned Partner Center handoff for Store ID 9NWTH4KJX5GW; no QA certificate or public GitHub asset is included."
