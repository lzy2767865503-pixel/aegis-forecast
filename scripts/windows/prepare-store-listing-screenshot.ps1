[CmdletBinding()]
param([switch]$ValidatePublicOnly)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true
Set-StrictMode -Version Latest

if (-not $IsWindows) { throw "Store listing screenshot publication requires the verified Windows runner." }
$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Set-Location $ProjectRoot
$CandidatePath = Join-Path $ProjectRoot 'artifacts\candidate\candidate.json'
$QaOnePath = Join-Path $ProjectRoot 'artifacts\qa\round-1\lifecycle-dom-api-uninstall.json'
$QaTwoPath = Join-Path $ProjectRoot 'artifacts\qa\round-2\lifecycle-dom-api-uninstall.json'
$CanonicalPath = Join-Path $ProjectRoot 'artifacts\private-summary\canonical-verification.json'
$PublicRoot = Join-Path $ProjectRoot 'artifacts\store-listing-public'
$ExpectedScreenshots = @(
    [ordered]@{ source = 'store-listing-home.png'; public = 'Quant-Scenario-Studio-Store-01-Home.png'; view = 'home'; heading = 'Nasdaq-100 说明性合成情景' },
    [ordered]@{ source = 'store-listing-scenarios.png'; public = 'Quant-Scenario-Studio-Store-02-Scenarios.png'; view = 'scenarios'; heading = 'Nasdaq-100 研究排名' },
    [ordered]@{ source = 'store-listing-privacy.png'; public = 'Quant-Scenario-Studio-Store-03-Privacy.png'; view = 'privacy'; heading = '隐私与本地数据' },
    [ordered]@{ source = 'store-listing-about.png'; public = 'Quant-Scenario-Studio-Store-04-About.png'; view = 'about'; heading = '关于 Quant Scenario Studio' }
)

function Read-UInt32BigEndian([byte[]]$Bytes, [int]$Offset) {
    if ($Offset -lt 0 -or $Offset + 4 -gt $Bytes.Length) { throw "PNG integer is outside the file boundary." }
    return [uint32]((([uint64]$Bytes[$Offset]) -shl 24) -bor
        (([uint64]$Bytes[$Offset + 1]) -shl 16) -bor
        (([uint64]$Bytes[$Offset + 2]) -shl 8) -bor
        ([uint64]$Bytes[$Offset + 3]))
}

function Get-StrictPngEvidence([string]$Path) {
    $Item = Get-Item -LiteralPath $Path -Force
    if ($Item.Length -lt 10000 -or $Item.Length -gt 20MB -or
        ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Store listing screenshot size or file boundary is invalid."
    }
    [byte[]]$Bytes = [IO.File]::ReadAllBytes($Item.FullName)
    if ($Bytes.Length -lt 45 -or [Convert]::ToHexString($Bytes[0..7]) -cne '89504E470D0A1A0A') {
        throw "Store listing screenshot is not a canonical PNG stream."
    }
    $AllowedChunks = @('IHDR', 'PLTE', 'IDAT', 'IEND', 'tRNS', 'cHRM', 'gAMA', 'sBIT', 'sRGB', 'bKGD', 'hIST', 'pHYs')
    $Position = 8
    $Chunks = [Collections.Generic.List[string]]::new()
    $Width = 0
    $Height = 0
    while ($Position -lt $Bytes.Length) {
        if ($Position + 12 -gt $Bytes.Length) { throw "PNG chunk header is truncated." }
        $Length = [long](Read-UInt32BigEndian $Bytes $Position)
        $Type = [Text.Encoding]::ASCII.GetString($Bytes, $Position + 4, 4)
        if ($Type -cnotmatch '^[A-Za-z]{4}$' -or $Type -cnotin $AllowedChunks -or
            $Length -gt 20MB -or $Position + 12 + $Length -gt $Bytes.Length) {
            throw "PNG contains an unknown, metadata-bearing, or out-of-bound chunk."
        }
        $Chunks.Add($Type)
        if ($Chunks.Count -eq 1) {
            if ($Type -cne 'IHDR' -or $Length -ne 13) { throw "PNG must start with one exact IHDR chunk." }
            $Width = [int](Read-UInt32BigEndian $Bytes ($Position + 8))
            $Height = [int](Read-UInt32BigEndian $Bytes ($Position + 12))
        } elseif ($Type -ceq 'IHDR') { throw "PNG contains more than one IHDR chunk." }
        $Position += 12 + [int]$Length
        if ($Type -ceq 'IEND') {
            if ($Length -ne 0 -or $Position -ne $Bytes.Length) { throw "PNG IEND is not exact and terminal." }
            break
        }
    }
    if ($Chunks.Count -lt 3 -or $Chunks[$Chunks.Count - 1] -cne 'IEND' -or
        @($Chunks | Where-Object { $_ -ceq 'IDAT' }).Count -lt 1 -or
        $Width -lt 1366 -or $Height -lt 768 -or $Width -gt 4096 -or $Height -gt 2160) {
        throw "PNG structure or 1366x768 minimum dimensions are invalid."
    }
    return [pscustomobject]@{
        sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $Item.FullName).Hash.ToLowerInvariant()
        width = $Width
        height = $Height
    }
}

if ($ValidatePublicOnly) {
    $HashEnvironmentNames = @(
        'AEGIS_STORE_SCREENSHOT_01_SHA256', 'AEGIS_STORE_SCREENSHOT_02_SHA256',
        'AEGIS_STORE_SCREENSHOT_03_SHA256', 'AEGIS_STORE_SCREENSHOT_04_SHA256'
    )
    if ($env:AEGIS_STORE_SCREENSHOT_WIDTH -cnotmatch '^\d{4}$' -or
        $env:AEGIS_STORE_SCREENSHOT_HEIGHT -cnotmatch '^\d{3,4}$' -or
        [int]$env:AEGIS_STORE_SCREENSHOT_WIDTH -lt 1366 -or [int]$env:AEGIS_STORE_SCREENSHOT_WIDTH -gt 4096 -or
        [int]$env:AEGIS_STORE_SCREENSHOT_HEIGHT -lt 768 -or [int]$env:AEGIS_STORE_SCREENSHOT_HEIGHT -gt 2160) {
        throw "Post-cleanup Store screenshot dimensions are missing or malformed."
    }
    $ExpectedPublicNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($Expected in $ExpectedScreenshots) { [void]$ExpectedPublicNames.Add([string]$Expected.public) }
    $PublicInventory = @(Get-ChildItem -LiteralPath $PublicRoot -Force)
    if ($PublicInventory.Count -ne 4 -or
        @($PublicInventory | Where-Object { $_.PSIsContainer -or -not $ExpectedPublicNames.Contains($_.Name) }).Count -ne 0) {
        throw "Post-cleanup Store screenshot staging is not the exact four-file PNG inventory."
    }
    for ($Index = 0; $Index -lt $ExpectedScreenshots.Count; $Index++) {
        $ExpectedHash = [Environment]::GetEnvironmentVariable($HashEnvironmentNames[$Index], 'Process')
        $PublicPath = Join-Path $PublicRoot ([string]$ExpectedScreenshots[$Index].public)
        $Evidence = Get-StrictPngEvidence -Path $PublicPath
        if ($ExpectedHash -cnotmatch '^[0-9a-f]{64}$' -or $Evidence.sha256 -cne $ExpectedHash -or
            $Evidence.width -ne [int]$env:AEGIS_STORE_SCREENSHOT_WIDTH -or
            $Evidence.height -ne [int]$env:AEGIS_STORE_SCREENSHOT_HEIGHT) {
            throw "A post-cleanup Store screenshot differs from its exact verified-candidate hash."
        }
    }
    Write-Host "Post-cleanup four-PNG Store screenshot inventory is exact and frozen."
    return
}

foreach ($Required in @($CandidatePath, $QaOnePath, $QaTwoPath, $CanonicalPath) + @(
    $ExpectedScreenshots | ForEach-Object { Join-Path $ProjectRoot "artifacts\qa\round-2\$($_.source)" }
)) {
    if (-not (Test-Path -LiteralPath $Required -PathType Leaf)) { throw "Verified screenshot input is missing: $Required" }
}
if (Test-Path -LiteralPath $PublicRoot) { throw "Public Store screenshot staging must not preexist." }
$Candidate = Get-Content -Raw -LiteralPath $CandidatePath | ConvertFrom-Json
$QaOne = Get-Content -Raw -LiteralPath $QaOnePath | ConvertFrom-Json
$QaTwo = Get-Content -Raw -LiteralPath $QaTwoPath | ConvertFrom-Json
$Canonical = Get-Content -Raw -LiteralPath $CanonicalPath | ConvertFrom-Json
$HeadCommit = (& git rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $HeadCommit -cnotmatch '^[0-9a-f]{40}$' -or
    $Candidate.sourceCommit -cne $HeadCommit -or $QaOne.sourceCommit -cne $HeadCommit -or
    $QaTwo.sourceCommit -cne $HeadCommit -or $Canonical.sourceCommit -cne $HeadCommit -or
    $Candidate.author -cne 'LAI ZEYU（来泽宇）' -or $Candidate.publisherDisplayName -cne 'LAI ZEYU' -or
    $Candidate.packageSha256 -cne $QaOne.packageSha256After -or
    $Candidate.packageSha256 -cne $QaTwo.packageSha256After -or
    $Candidate.packageSha256 -cne $Canonical.qaCandidatePackageSha256 -or
    $Candidate.submissionPackageSha256 -cne $QaTwo.submissionPackageSha256 -or
    $Candidate.submissionPackageSha256 -cne $Canonical.submissionPackageSha256 -or
    (@($Canonical.qaRounds) -join '|') -cne 'PASS|PASS' -or
    (@($Canonical.wackRounds) -join '|') -cne 'PASS|PASS') {
    throw "Store screenshot is not bound to the exact twice-QA/twice-WACK candidate lineage."
}
foreach ($Qa in @($QaOne, $QaTwo)) {
    if ($Qa.storeListingScreenshotFile -cne 'store-listing-home.png' -or
        $Qa.storeListingScreenshotSha256 -cnotmatch '^[0-9a-f]{64}$' -or
        $Qa.storeListingScreenshotView -cne 'home' -or -not $Qa.storeListingScreenshotPrivacyValidated -or
        [int]$Qa.storeListingScreenshotWidth -lt 1366 -or [int]$Qa.storeListingScreenshotHeight -lt 768 -or
        [int]$Qa.storeListingScreenshotCount -ne 4 -or @($Qa.storeListingScreenshots).Count -ne 4) {
        throw "A native QA round lacks its exact four privacy-validated Store screenshot views."
    }
    $SeenHashes = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    for ($Index = 0; $Index -lt $ExpectedScreenshots.Count; $Index++) {
        $Expected = $ExpectedScreenshots[$Index]
        $Screenshot = @($Qa.storeListingScreenshots)[$Index]
        $Keys = @($Screenshot.PSObject.Properties.Name | Sort-Object)
        if (($Keys -join '|') -cne 'fileName|heading|height|privacyValidated|sha256|view|width' -or
            [string]$Screenshot.fileName -cne [string]$Expected.source -or
            [string]$Screenshot.view -cne [string]$Expected.view -or
            [string]$Screenshot.heading -cne [string]$Expected.heading -or
            [string]$Screenshot.sha256 -cnotmatch '^[0-9a-f]{64}$' -or -not $Screenshot.privacyValidated -or
            -not $SeenHashes.Add([string]$Screenshot.sha256) -or
            [int]$Screenshot.width -ne [int]$Qa.storeListingScreenshotWidth -or
            [int]$Screenshot.height -ne [int]$Qa.storeListingScreenshotHeight) {
            throw "A native QA screenshot inventory is malformed, duplicated, or dimensionally inconsistent."
        }
    }
}
if ([string]$QaOne.nonce -ceq [string]$QaTwo.nonce -or
    [int]$QaOne.storeListingScreenshotWidth -ne [int]$QaTwo.storeListingScreenshotWidth -or
    [int]$QaOne.storeListingScreenshotHeight -ne [int]$QaTwo.storeListingScreenshotHeight) {
    throw "The two independent four-view candidate screenshot rounds are not distinct and dimensionally consistent."
}
$PackagePath = Join-Path ([IO.Path]::GetDirectoryName($CandidatePath)) ([string]$Candidate.packageFile)
$SubmissionPath = Join-Path ([IO.Path]::GetDirectoryName($CandidatePath)) ([string]$Candidate.submissionPackageFile)
if ((Get-FileHash -Algorithm SHA256 -LiteralPath $PackagePath).Hash.ToLowerInvariant() -cne $Candidate.packageSha256 -or
    (Get-FileHash -Algorithm SHA256 -LiteralPath $SubmissionPath).Hash.ToLowerInvariant() -cne $Candidate.submissionPackageSha256) {
    throw "Candidate bytes changed before screenshot publication."
}

New-Item -ItemType Directory -Path $PublicRoot | Out-Null
$ExpectedPublicNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$PublicEvidenceRows = [Collections.Generic.List[object]]::new()
for ($Index = 0; $Index -lt $ExpectedScreenshots.Count; $Index++) {
    $Expected = $ExpectedScreenshots[$Index]
    $SummaryScreenshot = @($QaTwo.storeListingScreenshots)[$Index]
    $ScreenshotPath = Join-Path $ProjectRoot "artifacts\qa\round-2\$([string]$Expected.source)"
    $Evidence = Get-StrictPngEvidence -Path $ScreenshotPath
    if ($Evidence.sha256 -cne [string]$SummaryScreenshot.sha256 -or
        $Evidence.width -ne [int]$SummaryScreenshot.width -or $Evidence.height -ne [int]$SummaryScreenshot.height) {
        throw "A publishable screenshot differs from exact QA round 2: $([string]$Expected.view)."
    }
    $PublicPath = Join-Path $PublicRoot ([string]$Expected.public)
    Copy-Item -LiteralPath $ScreenshotPath -Destination $PublicPath
    $PublicEvidence = Get-StrictPngEvidence -Path $PublicPath
    if ($PublicEvidence.sha256 -cne $Evidence.sha256 -or $PublicEvidence.width -ne $Evidence.width -or
        $PublicEvidence.height -ne $Evidence.height -or -not $ExpectedPublicNames.Add([string]$Expected.public)) {
        throw "A public Store screenshot changed during exact staging."
    }
    $PublicEvidenceRows.Add($PublicEvidence)
}
$PublicInventory = @(Get-ChildItem -LiteralPath $PublicRoot -Force)
if ($PublicInventory.Count -ne 4 -or @($PublicInventory | Where-Object { $_.PSIsContainer -or -not $ExpectedPublicNames.Contains($_.Name) }).Count -ne 0) {
    throw "Public Store screenshot staging is not the exact four-file PNG inventory."
}
if ($env:GITHUB_ENV) {
    "AEGIS_STORE_SCREENSHOT_WIDTH=$($QaTwo.storeListingScreenshotWidth)" >> $env:GITHUB_ENV
    "AEGIS_STORE_SCREENSHOT_HEIGHT=$($QaTwo.storeListingScreenshotHeight)" >> $env:GITHUB_ENV
    for ($Index = 0; $Index -lt $PublicEvidenceRows.Count; $Index++) {
        $Number = ($Index + 1).ToString('00', [Globalization.CultureInfo]::InvariantCulture)
        "AEGIS_STORE_SCREENSHOT_$($Number)_SHA256=$($PublicEvidenceRows[$Index].sha256)" >> $env:GITHUB_ENV
    }
}
if ($env:GITHUB_STEP_SUMMARY) {
    "- Store listing screenshots: four distinct exact-candidate views (home/scenarios/privacy/about), $($QaTwo.storeListingScreenshotWidth)x$($QaTwo.storeListingScreenshotHeight); PNG files only, no binary package uploaded" |
        Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Encoding utf8
}
Write-Host "Prepared four distinct exact privacy-validated Store views; unsigned candidate bytes remain private."
