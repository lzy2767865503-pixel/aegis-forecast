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
if (-not (Test-Path ".venv-windows\Scripts\python.exe")) { throw "Run setup.ps1 first." }
if (-not $env:RUNNER_TEMP) { throw "RUNNER_TEMP is required for isolated Windows verification." }

$Python = ".venv-windows\Scripts\python.exe"
$env:PYTHONPATH = "backend;."
$RunId = [guid]::NewGuid().ToString("N")
$TestData = Join-Path $env:RUNNER_TEMP "aegis-pass1-tests-$RunId"
$BoundaryData = Join-Path $env:RUNNER_TEMP "aegis-boundary-$RunId"
$PreviousSession = $env:AEGIS_SESSION_TOKEN
$PreviousCsrf = $env:AEGIS_CSRF_TOKEN
$PreviousData = $env:AEGIS_DATA_ROOT
$PreviousBinding = $env:AEGIS_DATA_ROOT_BINDING
$Backend = $null
$BackendOwnership = $null
$TempRoots = @($TestData, $BoundaryData)
$PrimaryFailure = $null

try {
    $env:AEGIS_DATA_ROOT = $TestData
    $env:AEGIS_DATA_ROOT_BINDING = "TEST:windows-pass1-$RunId"

    & $Python scripts\generate_demo_data.py --check
    Assert-NativeSuccess "deterministic scenario check"
    & $Python scripts\verify_attribution.py
    Assert-NativeSuccess "attribution verification"
    & $Python scripts\windows\generate_store_assets.py --check
    Assert-NativeSuccess "Store asset verification"
    & $Python scripts\privacy_scan.py --history
    Assert-NativeSuccess "privacy history scan"
    & $Python -m unittest discover -s tests -v
    Assert-NativeSuccess "Python unit tests"
    & scripts\windows\policy-selftest.ps1
    & $Python -m pip check
    Assert-NativeSuccess "pip dependency check"
    & $Python -m pip_audit -r requirements.lock.txt
    Assert-NativeSuccess "runtime pip audit"
    & $Python -m pip_audit -r requirements-windows-build.lock.txt
    Assert-NativeSuccess "Windows build pip audit"
    & $Python -m bandit -q -r backend -lll
    Assert-NativeSuccess "Bandit high-severity scan"
    pnpm --dir frontend audit --prod
    Assert-NativeSuccess "production pnpm audit"
    pnpm --dir frontend audit
    Assert-NativeSuccess "full pnpm audit"
    pnpm --dir frontend build
    Assert-NativeSuccess "frontend production build"

    & scripts\windows\build-backend.ps1
    $Project = "desktop\windows\AegisForecast\AegisForecast.csproj"
    dotnet restore $Project -r win-x64 --locked-mode -p:Platform=x64
    Assert-NativeSuccess "locked NuGet restore during pass 1"
    $NuGetRoot = if ($env:NUGET_PACKAGES) { $env:NUGET_PACKAGES } else { Join-Path $env:USERPROFILE ".nuget\packages" }
    & $Python scripts\windows\collect-nuget-licenses.py `
        --lock desktop\windows\AegisForecast\packages.lock.json `
        --nuget-root $NuGetRoot `
        --output artifacts\backend\AegisBackend\Legal\NuGet
    Assert-NativeSuccess "NuGet license collection"
    & scripts\windows\backend-hashes.ps1 -Mode Write

    $BackendExe = "artifacts\backend\AegisBackend\AegisBackend.exe"
    $FallbackRoot = Join-Path $env:LOCALAPPDATA "AegisForecast\LocalState"
    if (Test-Path -LiteralPath $FallbackRoot) {
        throw "Unpackaged fallback LocalState existed before boundary verification: $FallbackRoot"
    }
    $env:AEGIS_DATA_ROOT = $BoundaryData
    $env:AEGIS_DATA_ROOT_BINDING = "TEST:packaged-boundary-$RunId"
    $BoundaryOutput = @(& $BackendExe --check-packaged-imports 2>&1)
    Assert-NativeSuccess "frozen Store dependency-boundary check"
    if (-not (($BoundaryOutput -join "`n").Contains("PACKAGED_BOUNDARY_OK=no-account-sdk-no-execution-modules", [StringComparison]::Ordinal))) {
        throw "Frozen Store dependency-boundary success token is missing."
    }
    if (Test-Path -LiteralPath $BoundaryData) {
        $BoundaryWrites = @(Get-ChildItem -LiteralPath $BoundaryData -Force -ErrorAction SilentlyContinue)
        if ($BoundaryWrites.Count -ne 0) { throw "Packaged dependency-boundary check wrote mutable data." }
    }
    if (Test-Path -LiteralPath $FallbackRoot) { throw "Boundary self-check created unpackaged fallback LocalState." }

    $env:AEGIS_DATA_ROOT = $TestData
    $env:AEGIS_DATA_ROOT_BINDING = "TEST:windows-pass1-$RunId"
    $Listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $Listener.Start()
    $Port = ([System.Net.IPEndPoint]$Listener.LocalEndpoint).Port
    $Listener.Stop()
    $Token = "windows-pass1-session-token-00000000000000000001"
    $Csrf = "windows-pass1-csrf-token-0000000000000000000001"
    New-Item -ItemType Directory -Force -Path "artifacts\test-logs" | Out-Null
    $Stdout = Join-Path $ProjectRoot "artifacts\test-logs\backend-stdout.log"
    $Stderr = Join-Path $ProjectRoot "artifacts\test-logs\backend-stderr.log"
    $env:AEGIS_SESSION_TOKEN = $Token
    $env:AEGIS_CSRF_TOKEN = $Csrf
    $Backend = Start-Process $BackendExe `
        -ArgumentList "--host", "127.0.0.1", "--port", $Port, "--parent-pid", $PID `
        -PassThru -NoNewWindow -RedirectStandardOutput $Stdout -RedirectStandardError $Stderr
    $BackendTicks = $Backend.StartTime.ToUniversalTime().Ticks
    $ExpectedBackendPath = [IO.Path]::GetFullPath((Resolve-Path $BackendExe).Path)
    $BackendOwnership = [pscustomobject]@{
        processId = [int]$Backend.Id
        executablePath = $ExpectedBackendPath
        creationTimeUtcTicks = [long]$BackendTicks
    }
    if (-not [IO.Path]::GetFullPath($Backend.Path).Equals($ExpectedBackendPath, [StringComparison]::OrdinalIgnoreCase)) { throw "Started pass-1 backend path differs from the frozen sidecar." }
    $Headers = @{ "X-Aegis-Session" = $Token }
    $Health = $null
    for ($Attempt = 0; $Attempt -lt 60; $Attempt++) {
        try {
            $Health = Invoke-RestMethod "http://127.0.0.1:$Port/api/health" -Headers $Headers -TimeoutSec 2
            break
        } catch {
            Start-Sleep -Milliseconds 250
        }
    }
    if (-not $Health) { throw "Packaged backend did not become healthy. See $Stderr" }
    if (-not $Health.ok -or -not $Health.storeReadOnly -or $Health.executionEnabled) {
        throw "Packaged backend violated the Store read-only capability."
    }
    $Status = Invoke-RestMethod "http://127.0.0.1:$Port/api/status" -Headers $Headers -TimeoutSec 5
    $Signals = Invoke-RestMethod "http://127.0.0.1:$Port/api/signals?limit=1" -Headers $Headers -TimeoutSec 5
    $Data = Invoke-RestMethod "http://127.0.0.1:$Port/api/data" -Headers $Headers -TimeoutSec 5
    if ($Status.system.dataMode -ne "DETERMINISTIC_SYNTHETIC_SCENARIO" -or @($Signals.items).Count -ne 1 -or $Data.coverage.illustrativeOutcomeRows -ne 300) {
        throw "Core deterministic synthetic scenario APIs failed their smoke assertions."
    }
    $OrderResponse = Invoke-WebRequest "http://127.0.0.1:$Port/api/order/create" `
        -Method Post -ContentType "application/json" -Body "{}" `
        -Headers @{ "X-Aegis-Session" = $Token; "X-Aegis-CSRF" = $Csrf } `
        -SkipHttpErrorCheck
    if ($OrderResponse.StatusCode -ne 403) { throw "Packaged order route was not rejected." }
    $NoSession = Invoke-WebRequest "http://127.0.0.1:$Port/api/health" -SkipHttpErrorCheck
    if ($NoSession.StatusCode -ne 401) { throw "Packaged API allowed an unauthenticated request." }
} catch {
    $PrimaryFailure = $_.Exception
} finally {
    $FinalErrors = [Collections.Generic.List[string]]::new()
    if ($PrimaryFailure) { $FinalErrors.Add("verification: $($PrimaryFailure.Message)") }
    if ($BackendOwnership) {
        try {
            $Current = Get-Process -Id ([int]$BackendOwnership.processId) -ErrorAction SilentlyContinue
            if ($Current -and [IO.Path]::GetFullPath($Current.Path).Equals([string]$BackendOwnership.executablePath, [StringComparison]::OrdinalIgnoreCase) -and
                $Current.StartTime.ToUniversalTime().Ticks -eq [long]$BackendOwnership.creationTimeUtcTicks) {
                Stop-Process -Id ([int]$BackendOwnership.processId) -Force -ErrorAction Stop
                $Current.WaitForExit(30000)
            }
        } catch { $FinalErrors.Add("backend process: $($_.Exception.Message)") }
    } elseif ($Backend) {
        try {
            if (-not $Backend.HasExited) {
                $Backend.Kill($true)
                if (-not $Backend.WaitForExit(30000)) { throw "Started backend process tree remained after cleanup." }
            }
        } catch { $FinalErrors.Add("backend process handle: $($_.Exception.Message)") }
    }
    foreach ($Restore in @(
        [pscustomobject]@{ name = "AEGIS_SESSION_TOKEN"; value = $PreviousSession },
        [pscustomobject]@{ name = "AEGIS_CSRF_TOKEN"; value = $PreviousCsrf },
        [pscustomobject]@{ name = "AEGIS_DATA_ROOT"; value = $PreviousData },
        [pscustomobject]@{ name = "AEGIS_DATA_ROOT_BINDING"; value = $PreviousBinding }
    )) {
        try {
            if ($Restore.value) { [Environment]::SetEnvironmentVariable($Restore.name, [string]$Restore.value, "Process") }
            else { [Environment]::SetEnvironmentVariable($Restore.name, $null, "Process") }
        } catch { $FinalErrors.Add("environment $($Restore.name): $($_.Exception.Message)") }
    }
    $RunnerTemp = [System.IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd("\") + "\"
    foreach ($Root in $TempRoots) {
        try {
            $Exact = [System.IO.Path]::GetFullPath($Root)
            if (-not $Exact.StartsWith($RunnerTemp, [StringComparison]::OrdinalIgnoreCase)) { throw "Refusing to clean a pass-1 root outside RUNNER_TEMP." }
            if (Test-Path -LiteralPath $Exact) {
                $Entries = @(Get-ChildItem -LiteralPath $Exact -Force -Recurse -ErrorAction Stop | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 })
                $Item = Get-Item -LiteralPath $Exact -Force
                if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $Entries.Count -ne 0) { throw "Refusing to clean a reparse-point pass-1 tree." }
                Remove-Item -LiteralPath $Exact -Recurse -Force -ErrorAction Stop
            }
            if (Test-Path -LiteralPath $Exact) { throw "Pass-1 root remained after cleanup." }
        } catch { $FinalErrors.Add("root $Root`: $($_.Exception.Message)") }
    }
    if ($FinalErrors.Count -ne 0) { throw "Windows pass-1 verification/cleanup failures: $($FinalErrors -join ' | ')" }
}

Write-Host "Windows pass 1 complete: strict source/audit gates, frozen sidecar, isolated boundary and core API smoke passed."
