[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$CertificatePath,
    [Parameter(Mandatory = $true)][string]$CertificatePassword,
    [Parameter(Mandatory = $true)][string]$CertificatePublicPath,
    [Parameter(Mandatory = $true)][string]$StoreIdentityName,
    [Parameter(Mandatory = $true)][string]$StorePublisher
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "trusted-windows-sdk-tool.ps1")

function Assert-NativeSuccess([string]$Label) {
    if ($LASTEXITCODE -ne 0) { throw "$Label returned native exit code $LASTEXITCODE." }
}
$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
Set-Location $ProjectRoot
& scripts\windows\ensure-assets.ps1

$Project = "desktop\windows\AegisForecast\AegisForecast.csproj"
$ManifestTemplate = Join-Path $ProjectRoot "desktop\windows\AegisForecast\Package.appxmanifest"
$BackendExe = "artifacts\backend\AegisBackend\AegisBackend.exe"
if (-not (Test-Path $BackendExe)) { throw "Run scripts/windows/build-backend.ps1 first." }
& scripts\windows\backend-hashes.ps1 -Mode Verify
$ExpectedTechnicalPublisher = "CN=A5F91D0A-30C6-48EE-944F-B767FA872BE8"
$ExpectedStoreIdentityName = "LAIZEYU.QuantScenarioStudiobyLAIZEYU"
if ($StorePublisher -cne $ExpectedTechnicalPublisher) {
    throw "StorePublisher must be this account's exact Partner Center technical Publisher."
}
if ($StoreIdentityName -cne $ExpectedStoreIdentityName) {
    throw "StoreIdentityName must be the hard-locked Partner Center Identity Name for Store ID 9NWTH4KJX5GW."
}
$Pfx = (Resolve-Path $CertificatePath).Path
$Cer = (Resolve-Path $CertificatePublicPath).Path
if ([System.IO.Path]::GetExtension($Pfx) -ne ".pfx") { throw "CertificatePath must be an exact PFX file." }
if ([System.IO.Path]::GetExtension($Cer) -ne ".cer") { throw "CertificatePublicPath must be an exact CER file." }
$InputPublicCertificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($Cer)
$InputSigningCertificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
    $Pfx,
    $CertificatePassword,
    [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet
)
if ($InputPublicCertificate.Subject -cne $ExpectedTechnicalPublisher -or $InputSigningCertificate.Subject -cne $ExpectedTechnicalPublisher -or $InputPublicCertificate.Thumbprint -ne $InputSigningCertificate.Thumbprint) {
    throw "PFX and CER must match the Partner Center technical Publisher used by the Store package manifest."
}
$SourceCommit = (& git rev-parse HEAD).Trim()
Assert-NativeSuccess "git rev-parse HEAD"
if ($SourceCommit -notmatch "^[0-9a-f]{40}$") { throw "A full source commit is required." }

$BuildRoot = Join-Path $ProjectRoot "artifacts\msix-build"
$CandidateRoot = Join-Path $ProjectRoot "artifacts\candidate"
foreach ($Root in @($BuildRoot, $CandidateRoot)) {
    if (Test-Path -LiteralPath $Root) { throw "MSIX build/candidate root must not preexist: $Root" }
    New-Item -ItemType Directory -Path $Root | Out-Null
}
$GeneratedManifest = Join-Path $BuildRoot "Package.partner-center.appxmanifest"
$TemplateText = [System.IO.File]::ReadAllText($ManifestTemplate)
$GeneratedText = $TemplateText
[System.IO.File]::WriteAllText($GeneratedManifest, $GeneratedText, [System.Text.UTF8Encoding]::new($false))
[xml]$GeneratedXml = $GeneratedText
$GeneratedNamespace = [System.Xml.XmlNamespaceManager]::new($GeneratedXml.NameTable)
$GeneratedNamespace.AddNamespace("m", "http://schemas.microsoft.com/appx/manifest/foundation/windows10")
$GeneratedIdentity = $GeneratedXml.SelectSingleNode("/m:Package/m:Identity", $GeneratedNamespace)
$GeneratedPublisherDisplayName = $GeneratedXml.SelectSingleNode("/m:Package/m:Properties/m:PublisherDisplayName", $GeneratedNamespace)
if ($GeneratedIdentity.Name -cne $ExpectedStoreIdentityName -or $GeneratedIdentity.Publisher -cne $ExpectedTechnicalPublisher) {
    throw "Generated package manifest technical identity differs from the reserved Partner Center values."
}
if ($GeneratedPublisherDisplayName.InnerText -cne "LAI ZEYU") {
    throw "Visible PublisherDisplayName must remain exactly LAI ZEYU."
}

dotnet restore $Project -r win-x64 --locked-mode -p:Platform=x64
Assert-NativeSuccess "locked NuGet restore"
$NuGetLegal = "artifacts\backend\AegisBackend\Legal\NuGet\NUGET_LICENSE_MANIFEST.json"
if (-not (Test-Path $NuGetLegal)) { throw "Pass 1 NuGet legal evidence is missing from the frozen sidecar." }

$Properties = @(
    "-p:Platform=x64",
    "-p:GenerateAppxPackageOnBuild=true",
    "-p:AppxBundle=Never",
    "-p:AppxPackageDir=$BuildRoot\",
    "-p:AppxPackageSigningEnabled=false",
    "-p:AegisPackageManifestPath=$GeneratedManifest",
    "-p:ContinuousIntegrationBuild=true",
    "-p:SourceRevisionId=$SourceCommit",
    "-p:InformationalVersion=1.5.0+$SourceCommit",
    "-p:IncludeSourceRevisionInInformationalVersion=false"
)
dotnet publish $Project -c Release -r win-x64 --no-restore @Properties
Assert-NativeSuccess "WinUI/MSIX publish"

$Produced = @(Get-ChildItem $BuildRoot -Recurse -Filter *.msix -File)
if ($Produced.Count -ne 1) { throw "Expected exactly one MSIX, found $($Produced.Count)." }
$SubmissionMsix = Join-Path $CandidateRoot "QuantScenarioStudio_1.5.0.0_x64_store-unsigned.msix"
$CandidateMsix = Join-Path $CandidateRoot "QuantScenarioStudio_1.5.0.0_x64_signed-dev.msix"
$CandidateCer = Join-Path $CandidateRoot "QuantScenarioStudio_signed-dev.cer"
Copy-Item -LiteralPath $Produced[0].FullName -Destination $SubmissionMsix
Copy-Item -LiteralPath $SubmissionMsix -Destination $CandidateMsix
Copy-Item -LiteralPath $Cer -Destination $CandidateCer

$UnsignedSignature = Get-AuthenticodeSignature -LiteralPath $SubmissionMsix
if ($UnsignedSignature.Status -ne [Management.Automation.SignatureStatus]::NotSigned -or $UnsignedSignature.SignerCertificate) {
    throw "The one-build Partner Center submission MSIX is not unsigned."
}
$Signtool = Get-AegisTrustedWindowsSdkTool -Name "signtool.exe"
& $Signtool sign /fd SHA256 /f $Pfx /p $CertificatePassword $CandidateMsix | Out-Host
Assert-NativeSuccess "temporary QA MSIX signing"
$PublicCertificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($CandidateCer)
if ($PublicCertificate.Thumbprint -notmatch "^[0-9A-F]{40}$") { throw "Public CER thumbprint is invalid." }
if ($PublicCertificate.Subject -cne $ExpectedTechnicalPublisher) { throw "Development certificate must match the Partner Center technical Publisher." }
$Signature = Assert-AegisValidAppPackageSignature `
    -Path $CandidateMsix `
    -ExpectedCertificateThumbprint $PublicCertificate.Thumbprint `
    -ExpectedCertificateSubject $ExpectedTechnicalPublisher
$Equivalence = & scripts\windows\msix-payload-equivalence.ps1 `
    -SubmissionMsixPath $SubmissionMsix `
    -QaMsixPath $CandidateMsix `
    -ExpectedQaCertificateThumbprint $PublicCertificate.Thumbprint
$PackageHash = [string]$Equivalence.qaPackageSha256
$SubmissionHash = [string]$Equivalence.submissionPackageSha256
$CertificateHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $CandidateCer).Hash.ToLowerInvariant()
$Manifest = [ordered]@{
    schemaVersion = 3
    product = "Quant Scenario Studio by LAI ZEYU"
    author = "LAI ZEYU（来泽宇）"
    publisherDisplayName = "LAI ZEYU"
    uiLanguage = "zh-CN"
    packageIdentity = $StoreIdentityName
    packagePublisher = $ExpectedTechnicalPublisher
    packageVersion = "1.5.0.0"
    architecture = "x64"
    sourceCommit = $SourceCommit
    packageFile = [System.IO.Path]::GetFileName($CandidateMsix)
    packageSize = [long]$Equivalence.qaPackageSize
    packageSha256 = $PackageHash
    submissionPackageFile = [System.IO.Path]::GetFileName($SubmissionMsix)
    submissionPackageSize = [long]$Equivalence.submissionPackageSize
    submissionPackageSha256 = $SubmissionHash
    payloadFileCount = [int]$Equivalence.payloadFileCount
    payloadTreeSha256 = [string]$Equivalence.payloadTreeSha256
    certificateFile = [System.IO.Path]::GetFileName($CandidateCer)
    certificateSha256 = $CertificateHash
    certificateThumbprint = $PublicCertificate.Thumbprint
    certificateSubject = $PublicCertificate.Subject
    developmentCertificateRole = "PartnerCenterTechnicalPublisherOnly"
    signedDevelopmentCandidate = $true
    unsignedStoreSubmission = $true
}
$Manifest | ConvertTo-Json -Depth 4 | Set-Content -Encoding utf8 (Join-Path $CandidateRoot "candidate.json")
"$PackageHash  $([System.IO.Path]::GetFileName($CandidateMsix))" | Set-Content -Encoding ascii (Join-Path $CandidateRoot "QA-SHA256.txt")
"$SubmissionHash  $([System.IO.Path]::GetFileName($SubmissionMsix))" | Set-Content -Encoding ascii (Join-Path $CandidateRoot "STORE-SUBMISSION-SHA256.txt")
Write-Host "Built one unsigned Store submission MSIX ($SubmissionHash), copied it once, and signed only the payload-equivalent QA copy ($PackageHash)."
