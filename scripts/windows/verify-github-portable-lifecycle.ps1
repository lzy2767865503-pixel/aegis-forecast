[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ArchivePath,
    [Parameter(Mandatory = $true)][ValidateSet("1", "2")][string]$QaRound
)
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
if (-not $IsWindows) { throw "Portable lifecycle verification requires Windows." }
$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$Archive = (Resolve-Path $ArchivePath).Path
$HashBefore = (Get-FileHash -Algorithm SHA256 -LiteralPath $Archive).Hash.ToLowerInvariant()
$SourceCommit = (& git -C $ProjectRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $SourceCommit -cnotmatch "^[0-9a-f]{40}$") { throw "Portable lifecycle requires a full source commit." }
$DataParent = Join-Path $env:LOCALAPPDATA "AegisForecast"
$DataRoot = Join-Path $DataParent "LocalState"
if (Test-Path -LiteralPath $DataRoot) { throw "Fail-closed: portable application data already exists." }
if (Test-Path -LiteralPath $DataParent) {
    $DataParentItem = Get-Item -LiteralPath $DataParent -Force
    if (($DataParentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Fail-closed: portable application data parent is a reparse point." }
}
if (@(Get-Process -Name "QuantScenarioStudio", "AegisBackend" -ErrorAction SilentlyContinue).Count -ne 0) { throw "Fail-closed: a same-named process already exists." }
if (-not $env:RUNNER_TEMP) { throw "RUNNER_TEMP is required." }
$TempRoot = Join-Path $env:RUNNER_TEMP ("aegis-portable-qa-$QaRound-" + [Guid]::NewGuid().ToString("N"))
$Owned = @{}
$DataRootCreationAttempted = $false
$DataParentCreated = -not (Test-Path -LiteralPath $DataParent)
$PrimaryFailure = $null
$Started = $null
try {
    $ArchiveEvidence = & (Join-Path $PSScriptRoot 'verify-portable-archive.ps1') -ArchivePath $Archive -DestinationPath $TempRoot
    $ProductRoot = [string]$ArchiveEvidence.productRoot
    & (Join-Path $PSScriptRoot "verify-github-signatures.ps1") -Root $ProductRoot
    $ShellPath = [IO.Path]::GetFullPath((Join-Path $ProductRoot "QuantScenarioStudio.exe"))
    $BackendPath = [IO.Path]::GetFullPath((Join-Path $ProductRoot "Backend\AegisBackend.exe"))
    if (-not (Test-Path -LiteralPath $ShellPath) -or -not (Test-Path -LiteralPath $BackendPath)) { throw "Portable ZIP shell or sidecar is missing." }
    $Runtime = Join-Path $DataRoot "runtime"
    $DataRootCreationAttempted = $true
    New-Item -ItemType Directory -Path $DataRoot | Out-Null
    New-Item -ItemType Directory -Path $Runtime | Out-Null
    $Nonce = ([Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))).ToLowerInvariant()
    [ordered]@{ packageSha256 = $HashBefore; sourceCommit = $SourceCommit; qaRound = $QaRound; nonce = $Nonce } | ConvertTo-Json | Set-Content -Encoding utf8 (Join-Path $Runtime "qa_expected.json")
    $Started = Start-Process -FilePath $ShellPath -WorkingDirectory $ProductRoot -PassThru
    $StartedTicks = $Started.StartTime.ToUniversalTime().Ticks
    $Owned["$($Started.Id)|$StartedTicks"] = [pscustomobject]@{ processId = [int]$Started.Id; executablePath = $ShellPath; creationTimeUtcTicks = [long]$StartedTicks }
    $StartedPath = [IO.Path]::GetFullPath($Started.Path)
    if (-not $StartedPath.Equals($ShellPath, [StringComparison]::OrdinalIgnoreCase)) { throw "Started portable shell path differs from the staged executable." }
    $ReadyPath = Join-Path $Runtime "ui_ready.json"
    $Marker = $null
    for ($Attempt = 0; $Attempt -lt 180; $Attempt++) {
        if (Test-Path -LiteralPath $ReadyPath) { try { $Marker = Get-Content -Raw -LiteralPath $ReadyPath | ConvertFrom-Json } catch { $Marker = $null } }
        if ($Marker) { break }
        Start-Sleep -Milliseconds 500
    }
    if (-not $Marker -or $Marker.nonce -cne $Nonce -or $Marker.sourceCommit -cne $SourceCommit -or $Marker.packageSha256 -cne $HashBefore -or [string]$Marker.qaRound -cne $QaRound) { throw "Portable DOM marker does not match this nonce-bound launch." }
    if ($Marker.product -cne "Quant Scenario Studio by LAI ZEYU" -or $Marker.author -cne "LAI ZEYU（来泽宇）" -or -not $Marker.apiHealthValidated -or -not $Marker.coreDataValidated -or -not $Marker.domDataReady) { throw "Portable DOM/API readiness is invalid." }
    if ($Marker.packageFamily -cne "UNPACKAGED_WINDOWS" -or $Marker.dataRootBinding -cne "UNPACKAGED_WINDOWS") { throw "Portable marker package/data binding is invalid." }
    if (-not [IO.Path]::GetFullPath([string]$Marker.installLocation).Equals([IO.Path]::GetFullPath($ProductRoot).TrimEnd("\"), [StringComparison]::OrdinalIgnoreCase)) { throw "Portable marker install location is invalid." }
    $ShellPid = [int]$Marker.shellProcessId
    $BackendPid = [int]$Marker.backendProcessId
    if ($ShellPid -ne [int]$Started.Id) { throw "Portable marker shell PID differs from the exact process started by this round." }
    $Shell = Get-Process -Id $ShellPid -ErrorAction Stop
    $Backend = Get-Process -Id $BackendPid -ErrorAction Stop
    $ShellActual = [IO.Path]::GetFullPath($Shell.Path)
    $BackendActual = [IO.Path]::GetFullPath($Backend.Path)
    if ($Shell.ProcessName -cne "QuantScenarioStudio" -or $Backend.ProcessName -cne "AegisBackend" -or
        -not $ShellActual.Equals($ShellPath, [StringComparison]::OrdinalIgnoreCase) -or -not $BackendActual.Equals($BackendPath, [StringComparison]::OrdinalIgnoreCase) -or
        -not [IO.Path]::GetFullPath([string]$Marker.shellExecutablePath).Equals($ShellPath, [StringComparison]::OrdinalIgnoreCase) -or
        -not [IO.Path]::GetFullPath([string]$Marker.backendExecutablePath).Equals($BackendPath, [StringComparison]::OrdinalIgnoreCase)) { throw "Portable marker PIDs/names/canonical paths are invalid." }
    $ShellTicks = $Shell.StartTime.ToUniversalTime().Ticks
    $BackendTicks = $Backend.StartTime.ToUniversalTime().Ticks
    $Owned["$ShellPid|$ShellTicks"] = [pscustomobject]@{ processId = $ShellPid; executablePath = $ShellPath; creationTimeUtcTicks = [long]$ShellTicks }
    $Owned["$BackendPid|$BackendTicks"] = [pscustomobject]@{ processId = $BackendPid; executablePath = $BackendPath; creationTimeUtcTicks = [long]$BackendTicks }
    Stop-Process -Id $ShellPid -Force -ErrorAction Stop
    for ($Attempt = 0; $Attempt -lt 60; $Attempt++) {
        $CurrentBackend = Get-Process -Id $BackendPid -ErrorAction SilentlyContinue
        if (-not $CurrentBackend -or $CurrentBackend.StartTime.ToUniversalTime().Ticks -ne $BackendTicks) { break }
        Start-Sleep -Milliseconds 500
    }
    $CurrentShell = Get-Process -Id $ShellPid -ErrorAction SilentlyContinue
    $CurrentBackend = Get-Process -Id $BackendPid -ErrorAction SilentlyContinue
    if ($CurrentShell -and $CurrentShell.StartTime.ToUniversalTime().Ticks -eq $ShellTicks) { throw "Portable shell remained after force-kill." }
    if ($CurrentBackend -and $CurrentBackend.StartTime.ToUniversalTime().Ticks -eq $BackendTicks) { throw "Portable sidecar did not exit through the parent watchdog." }
    $OwnerPath = Join-Path $DataRoot ".quant-scenario-localstate.json"
    $Owner = Get-Content -Raw -LiteralPath $OwnerPath | ConvertFrom-Json
    if ($Owner.schemaVersion -ne 1 -or $Owner.product -cne "Quant Scenario Studio by LAI ZEYU" -or $Owner.binding -cne "UNPACKAGED_WINDOWS" -or
        -not [IO.Path]::GetFullPath([string]$Owner.canonicalRoot).Equals([IO.Path]::GetFullPath($DataRoot), [StringComparison]::OrdinalIgnoreCase)) { throw "Portable data root ownership marker is invalid." }
    $DataItem = Get-Item -LiteralPath $DataRoot -Force
    $DataReparse = @(Get-ChildItem -LiteralPath $DataRoot -Force -Recurse -ErrorAction Stop | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 })
    if (($DataItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $DataReparse.Count -ne 0) { throw "Portable data cleanup tree contains a reparse point." }
    Remove-Item -LiteralPath $DataRoot -Recurse -Force
    if (Test-Path -LiteralPath $DataRoot) { throw "Portable data cleanup failed." }
    $HashAfter = (Get-FileHash -Algorithm SHA256 -LiteralPath $Archive).Hash.ToLowerInvariant()
    if ($HashAfter -cne $HashBefore) { throw "Portable ZIP changed during QA round $QaRound." }
    Write-Host "Portable signed ZIP lifecycle round $QaRound passed on unchanged bytes $HashBefore."
} catch {
    $PrimaryFailure = $_.Exception
} finally {
    $FinalErrors = [Collections.Generic.List[string]]::new()
    if ($PrimaryFailure) { $FinalErrors.Add("verification: $($PrimaryFailure.Message)") }
    foreach ($Record in @($Owned.Values)) {
        try {
            $Process = Get-Process -Id ([int]$Record.processId) -ErrorAction SilentlyContinue
            if (-not $Process -or $Process.StartTime.ToUniversalTime().Ticks -ne [long]$Record.creationTimeUtcTicks) { continue }
            $Current = [IO.Path]::GetFullPath($Process.Path)
            if (-not $Current.Equals([string]$Record.executablePath, [StringComparison]::OrdinalIgnoreCase)) { continue }
            Stop-Process -Id ([int]$Record.processId) -Force -ErrorAction Stop
            $Process.WaitForExit(30000)
        } catch { $FinalErrors.Add("process $($Record.processId): $($_.Exception.Message)") }
    }
    if ($Started) {
        try {
            if (-not $Started.HasExited) {
                $Started.Kill($true)
                if (-not $Started.WaitForExit(30000)) { throw "Started portable process tree remained after cleanup." }
            }
        } catch { $FinalErrors.Add("started process handle: $($_.Exception.Message)") }
    }
    if ($DataRootCreationAttempted -and (Test-Path -LiteralPath $DataRoot)) {
        try {
            $ExpectedDataRoot = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA "AegisForecast\LocalState"))
            $ActualDataRoot = [IO.Path]::GetFullPath($DataRoot)
            if (-not $ActualDataRoot.Equals($ExpectedDataRoot, [StringComparison]::OrdinalIgnoreCase)) { throw "Refusing portable data cleanup outside the exact owned LocalState root." }
            $DataItem = Get-Item -LiteralPath $ActualDataRoot -Force
            $Reparse = @(Get-ChildItem -LiteralPath $ActualDataRoot -Force -Recurse -ErrorAction Stop | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 })
            if (($DataItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $Reparse.Count -ne 0) { throw "Refusing to clean a reparse-point portable LocalState tree." }
            Remove-Item -LiteralPath $ActualDataRoot -Recurse -Force -ErrorAction Stop
            if (Test-Path -LiteralPath $ActualDataRoot) { throw "Portable LocalState remained after cleanup." }
        } catch { $FinalErrors.Add("data root: $($_.Exception.Message)") }
    }
    if ($DataParentCreated -and (Test-Path -LiteralPath $DataParent)) {
        try {
            $ParentItem = Get-Item -LiteralPath $DataParent -Force
            if (($ParentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Refusing to clean a reparse-point portable data parent." }
            if (@(Get-ChildItem -LiteralPath $DataParent -Force -ErrorAction Stop).Count -eq 0) { Remove-Item -LiteralPath $DataParent -Force -ErrorAction Stop }
            if (Test-Path -LiteralPath $DataParent) { throw "Run-created portable data parent was not empty after LocalState cleanup." }
        } catch { $FinalErrors.Add("data parent: $($_.Exception.Message)") }
    }
    if (Test-Path -LiteralPath $TempRoot) {
        try {
            $Prefix = [IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd("\") + "\"
            $ExactTemp = [IO.Path]::GetFullPath($TempRoot)
            if (-not $ExactTemp.StartsWith($Prefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Refusing portable temp cleanup outside RUNNER_TEMP." }
            $TempItem = Get-Item -LiteralPath $ExactTemp -Force
            $TempReparse = @(Get-ChildItem -LiteralPath $ExactTemp -Force -Recurse -ErrorAction Stop | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 })
            if (($TempItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $TempReparse.Count -ne 0) { throw "Refusing to clean a reparse-point portable temp tree." }
            Remove-Item -LiteralPath $ExactTemp -Recurse -Force -ErrorAction Stop
            if (Test-Path -LiteralPath $ExactTemp) { throw "Portable temp root remained after cleanup." }
        } catch { $FinalErrors.Add("temp root: $($_.Exception.Message)") }
    }
    if ($FinalErrors.Count -ne 0) { throw "Portable lifecycle verification/cleanup failures: $($FinalErrors -join ' | ')" }
}
