[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true
Set-StrictMode -Version Latest

function Assert-NativeSuccess([string]$Label) {
    if ($LASTEXITCODE -ne 0) { throw "$Label returned native exit code $LASTEXITCODE." }
}
$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
Set-Location $ProjectRoot

if (-not (Test-Path ".venv-windows\Scripts\python.exe")) {
    throw "Run scripts/windows/setup.ps1 first."
}

pnpm --dir frontend build
Assert-NativeSuccess "frontend build"
$DistRoot = Join-Path $ProjectRoot "artifacts\backend"
$WorkRoot = Join-Path $ProjectRoot "artifacts\pyinstaller"
foreach ($Root in @($DistRoot, $WorkRoot)) {
    if (Test-Path -LiteralPath $Root) { throw "Frozen sidecar build root must not preexist: $Root" }
}
& .venv-windows\Scripts\python.exe -m PyInstaller `
    packaging\windows\aegis_backend.spec `
    --noconfirm --clean `
    --distpath $DistRoot `
    --workpath $WorkRoot
Assert-NativeSuccess "PyInstaller Store sidecar build"

$BackendExe = Join-Path $DistRoot "AegisBackend\AegisBackend.exe"
if (-not (Test-Path $BackendExe)) { throw "PyInstaller did not produce $BackendExe" }
& .venv-windows\Scripts\python.exe scripts\windows\collect-licenses.py `
    --output (Join-Path $DistRoot "AegisBackend\Legal\Runtime")
Assert-NativeSuccess "runtime license collection"
Write-Host "Built PyInstaller onedir sidecar: $BackendExe"
