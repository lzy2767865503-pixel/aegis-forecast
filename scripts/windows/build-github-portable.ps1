[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$OutputRoot
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true
Set-StrictMode -Version Latest
if (-not $IsWindows) { throw "The trusted GitHub portable build requires Windows." }
if ($env:AEGIS_TRUSTED_GITHUB_BUILD -cne "1") { throw "Refusing to build public bytes outside the protected trusted-release workflow." }

function Assert-NativeSuccess([string]$Label) {
    if ($LASTEXITCODE -ne 0) { throw "$Label returned native exit code $LASTEXITCODE." }
}

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
Set-Location $ProjectRoot
$ExactOutput = [IO.Path]::GetFullPath($OutputRoot)
$ExpectedPrefix = [IO.Path]::GetFullPath((Join-Path $ProjectRoot "artifacts\github-release")).TrimEnd("\") + "\"
if (-not $ExactOutput.StartsWith($ExpectedPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Portable output must remain under artifacts/github-release." }
if (Test-Path -LiteralPath $ExactOutput) { throw "Portable output root must not preexist." }
New-Item -ItemType Directory -Path $ExactOutput | Out-Null

$SourceCommit = (& git rev-parse HEAD).Trim()
Assert-NativeSuccess "git rev-parse HEAD"
if ($SourceCommit -cnotmatch "^[0-9a-f]{40}$") { throw "A full source commit is required." }
if (-not (Test-Path "artifacts\backend\AegisBackend\AegisBackend.exe")) { throw "Build the frozen sidecar before the portable desktop shell." }
& scripts\windows\backend-hashes.ps1 -Mode Verify

$Project = "desktop\windows\AegisForecast\AegisForecast.csproj"
dotnet restore $Project -r win-x64 --locked-mode -p:Platform=x64
Assert-NativeSuccess "locked portable NuGet restore"
$Properties = @(
    "-p:Platform=x64",
    "-p:WindowsPackageType=None",
    "-p:GenerateAppxPackageOnBuild=false",
    "-p:AppxPackageSigningEnabled=false",
    "-p:AegisPortableBuild=true",
    "-p:ContinuousIntegrationBuild=true",
    "-p:SourceRevisionId=$SourceCommit",
    "-p:InformationalVersion=1.5.0+$SourceCommit",
    "-p:IncludeSourceRevisionInInformationalVersion=false"
)
dotnet publish $Project -c Release -r win-x64 --no-restore --self-contained true -o $ExactOutput @Properties
Assert-NativeSuccess "portable WinUI publish"

$Shell = Join-Path $ExactOutput "QuantScenarioStudio.exe"
$Backend = Join-Path $ExactOutput "Backend\AegisBackend.exe"
if (-not (Test-Path -LiteralPath $Shell) -or -not (Test-Path -LiteralPath $Backend)) { throw "Portable shell or sidecar is missing." }
$Version = (Get-Item -LiteralPath $Shell).VersionInfo
if ($Version.ProductName -cne "Quant Scenario Studio by LAI ZEYU" -or $Version.CompanyName -cne "LAI ZEYU" -or
    $Version.LegalCopyright -cne "Copyright © 2026 LAI ZEYU（来泽宇）" -or
    $Version.ProductVersion -cne "1.5.0+$SourceCommit") { throw "Portable VersionInfo/source lineage is invalid." }

$PortableEntries = @(Get-ChildItem -LiteralPath $ExactOutput -Recurse -Force)
if (@($PortableEntries | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 }).Count -ne 0) { throw "Portable output contains a reparse-point entry." }
foreach ($File in @($PortableEntries | Where-Object { -not $_.PSIsContainer })) {
    if ($File.Extension.ToLowerInvariant() -in @(".msix", ".appx", ".cer", ".crt", ".der", ".pem", ".p12", ".pfx", ".pvk", ".key")) { throw "Portable GitHub output contains a Store package or certificate/key container." }
}

[ordered]@{
    schemaVersion = 1
    product = "Quant Scenario Studio by LAI ZEYU"
    author = "LAI ZEYU（来泽宇）"
    sourceCommit = $SourceCommit
    packageKind = "portable-zip-not-store-msix"
    architecture = "x64"
} | ConvertTo-Json | Set-Content -Encoding utf8 (Join-Path $ExactOutput "RELEASE_LINEAGE.json")

Write-Host "Built the unsigned private staging directory for cloud-HSM signing: $ExactOutput"
