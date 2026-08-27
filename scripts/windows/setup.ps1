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

if (-not $IsWindows) { throw "Windows packaging must run on Windows." }

$PythonVersion = (& python --version 2>&1).ToString().Trim()
Assert-NativeSuccess "python --version"
if ($PythonVersion -ne "Python 3.13.14") {
    throw "Expected Python 3.13.14, found $PythonVersion"
}
$NodeVersion = (& node --version).Trim()
Assert-NativeSuccess "node --version"
if ($NodeVersion -ne "v22.23.1") {
    throw "Expected Node v22.23.1, found $NodeVersion"
}

corepack enable
Assert-NativeSuccess "corepack enable"
corepack prepare pnpm@10.34.5 --activate
Assert-NativeSuccess "corepack prepare"
$PnpmVersion = (pnpm --version).Trim()
Assert-NativeSuccess "pnpm --version"
if ($PnpmVersion -ne "10.34.5") { throw "pnpm 10.34.5 is required." }

if (-not (Test-Path ".venv-windows\Scripts\python.exe")) {
    python -m venv .venv-windows
    Assert-NativeSuccess "python -m venv"
}
& .venv-windows\Scripts\python.exe -m pip install --disable-pip-version-check `
    --require-hashes --no-deps `
    -r requirements-windows-build.lock.txt
Assert-NativeSuccess "fully hash-locked Python dependency install"
pnpm --dir frontend install --frozen-lockfile
Assert-NativeSuccess "frozen pnpm install"

Write-Host "Windows toolchain ready: Python 3.13.14, Node 22.23.1, pnpm 10.34.5."
