[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true
Set-StrictMode -Version Latest
$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
Set-Location $ProjectRoot
$Python = if (Test-Path ".venv-windows\Scripts\python.exe") {
    ".venv-windows\Scripts\python.exe"
} else {
    (Get-Command python -ErrorAction Stop).Source
}
& $Python scripts\windows\generate_store_assets.py --check
if ($LASTEXITCODE -ne 0) {
    throw "Committed first-party Store artwork is missing or stale. Regenerate and review it before packaging."
}

Write-Host "Verified first-party Store/MSIX artwork and all required scale variants."
