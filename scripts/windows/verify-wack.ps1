[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$MsixPath,
    [Parameter(Mandatory = $true)][string]$CandidateManifestPath,
    [Parameter(Mandatory = $true)][string]$CertificatePath,
    [Parameter(Mandatory = $true)][string]$ApprovedWackFileVersion,
    [Parameter(Mandatory = $true)][ValidateSet("1", "2")][string]$WackRound
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "wack-runner-policy.ps1")
$RunnerPolicy = Assert-AegisWackRunner -ApprovedFileVersion $ApprovedWackFileVersion
$CurrentSessionId = [int]$RunnerPolicy.sessionId
$AppCert = [string]$RunnerPolicy.appCertPath

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
Set-Location $ProjectRoot
$PackagePath = (Resolve-Path $MsixPath).Path
$ManifestPath = (Resolve-Path $CandidateManifestPath).Path
$CerPath = (Resolve-Path $CertificatePath).Path
$Candidate = Get-Content -Raw -LiteralPath $ManifestPath | ConvertFrom-Json
$SubmissionPath = (Resolve-Path -LiteralPath (Join-Path ([IO.Path]::GetDirectoryName($ManifestPath)) ([string]$Candidate.submissionPackageFile))).Path
$ExpectedStoreIdentityName = "LAIZEYU.QuantScenarioStudiobyLAIZEYU"
$ExpectedTechnicalPublisher = "CN=A5F91D0A-30C6-48EE-944F-B767FA872BE8"
. (Join-Path $PSScriptRoot "wack-report-policy.ps1")

if ($Candidate.schemaVersion -ne 3 -or -not $Candidate.signedDevelopmentCandidate -or -not $Candidate.unsignedStoreSubmission -or
    $Candidate.packageIdentity -cne $ExpectedStoreIdentityName -or
    $Candidate.packagePublisher -cne $ExpectedTechnicalPublisher -or
    $Candidate.certificateSubject -cne $ExpectedTechnicalPublisher -or
    $Candidate.publisherDisplayName -cne "LAI ZEYU" -or
    $Candidate.author -cne "LAI ZEYU（来泽宇）") {
    throw "WACK candidate does not separate the reserved technical identity from visible LAI ZEYU authorship."
}

function Assert-CandidateBytes([string]$Stage) {
    $Hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $PackagePath).Hash.ToLowerInvariant()
    $Size = (Get-Item -LiteralPath $PackagePath).Length
    if ($Hash -ne $Candidate.packageSha256 -or $Size -ne [long]$Candidate.packageSize) {
        throw "WACK input differs from the reviewed candidate at $Stage."
    }
    $SubmissionHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $SubmissionPath).Hash.ToLowerInvariant()
    if ($SubmissionHash -cne $Candidate.submissionPackageSha256 -or
        (Get-Item -LiteralPath $SubmissionPath).Length -ne [long]$Candidate.submissionPackageSize) {
        throw "Unsigned Store submission differs from the reviewed candidate lineage at $Stage."
    }
    $Equivalence = & scripts\windows\msix-payload-equivalence.ps1 `
        -SubmissionMsixPath $SubmissionPath `
        -QaMsixPath $PackagePath `
        -ExpectedQaCertificateThumbprint $Candidate.certificateThumbprint
    if ($Equivalence.payloadTreeSha256 -cne $Candidate.payloadTreeSha256 -or
        [int]$Equivalence.payloadFileCount -ne [int]$Candidate.payloadFileCount -or
        $Equivalence.submissionPackageSha256 -cne $Candidate.submissionPackageSha256 -or
        $Equivalence.qaPackageSha256 -cne $Candidate.packageSha256) {
        throw "WACK QA copy no longer has the exact unsigned-submission payload tree at $Stage."
    }
    return $Hash
}

function Test-PathWithin([string]$Child, [string]$Parent) {
    $ExactChild = [System.IO.Path]::GetFullPath($Child)
    $ExactParent = [System.IO.Path]::GetFullPath($Parent).TrimEnd("\")
    return $ExactChild.StartsWith($ExactParent + "\", [StringComparison]::OrdinalIgnoreCase)
}

function Get-ProcessDescendants {
    param([Parameter(Mandatory = $true)][int]$RootProcessId, [Parameter(Mandatory = $true)][object[]]$ProcessTable)
    $Known = [Collections.Generic.HashSet[int]]::new()
    [void]$Known.Add($RootProcessId)
    $Descendants = [Collections.Generic.List[object]]::new()
    do {
        $Added = $false
        foreach ($Record in $ProcessTable) {
            $RecordId = [int]$Record.ProcessId
            if ($RecordId -gt 0 -and $Known.Contains([int]$Record.ParentProcessId) -and $Known.Add($RecordId)) {
                $Descendants.Add($Record)
                $Added = $true
            }
        }
    } while ($Added)
    return @($Descendants)
}

function Get-CreationKey($Record) {
    if ($null -eq $Record.CreationDate) { return "" }
    return ([DateTime]$Record.CreationDate).ToUniversalTime().Ticks.ToString([Globalization.CultureInfo]::InvariantCulture)
}

function Assert-AppCertTreeExited {
    param([Parameter(Mandatory = $true)][int]$RootProcessId, [Parameter(Mandatory = $true)][object[]]$CapturedDescendants)
    $Captured = [Collections.Generic.Dictionary[int, string]]::new()
    foreach ($Record in $CapturedDescendants) { $Captured[[int]$Record.ProcessId] = Get-CreationKey $Record }
    for ($Attempt = 0; $Attempt -lt 60; $Attempt++) {
        $Current = @(Get-CimInstance -ClassName Win32_Process -OperationTimeoutSec 5 -ErrorAction Stop)
        $CurrentById = [Collections.Generic.Dictionary[int, object]]::new()
        foreach ($Record in $Current) { $CurrentById[[int]$Record.ProcessId] = $Record }
        $CapturedStillAlive = @(
            $Captured.GetEnumerator() | Where-Object {
                $CurrentById.ContainsKey($_.Key) -and (Get-CreationKey $CurrentById[$_.Key]) -ceq $_.Value
            }
        )
        $StillParentedToTree = @(Get-ProcessDescendants -RootProcessId $RootProcessId -ProcessTable $Current)
        if ($CapturedStillAlive.Count -eq 0 -and $StillParentedToTree.Count -eq 0) { return }
        Start-Sleep -Milliseconds 500
    }
    throw "AppCert hard-timeout cleanup left a captured or still-parented descendant process alive."
}

function Stop-ExactCapturedProcesses {
    param([Parameter(Mandatory = $true)][object[]]$CapturedProcesses)
    $Errors = [Collections.Generic.List[string]]::new()
    foreach ($Record in @($CapturedProcesses | Sort-Object ProcessId -Descending)) {
        try {
            $ProcessId = [int]$Record.ProcessId
            $ExpectedCreation = Get-CreationKey $Record
            $Current = @(Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $ProcessId" -OperationTimeoutSec 5 -ErrorAction Stop)
            if ($Current.Count -eq 0 -or (Get-CreationKey $Current[0]) -cne $ExpectedCreation) { continue }
            Stop-Process -Id $ProcessId -Force -ErrorAction Stop
        } catch { $Errors.Add("PID $($Record.ProcessId): $($_.Exception.Message)") }
    }
    if ($Errors.Count -ne 0) { throw "Exact AppCert descendant termination failed: $($Errors -join '; ')" }
}

function Invoke-BoundedAppCert {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds,
        [Parameter(Mandatory = $true)][string]$ConsoleLog,
        [switch]$CapturePackageOwnership
    )
    $Info = [System.Diagnostics.ProcessStartInfo]::new()
    $Info.FileName = $AppCert
    $Info.UseShellExecute = $false
    $Info.CreateNoWindow = $false
    $Info.RedirectStandardOutput = $true
    $Info.RedirectStandardError = $true
    foreach ($Argument in $Arguments) { [void]$Info.ArgumentList.Add($Argument) }
    $Process = [System.Diagnostics.Process]::new()
    $Process.StartInfo = $Info
    $ProcessStarted = $false
    $FailSafeCapturedDescendants = @()
    try {
    $StartedAt = [DateTimeOffset]::UtcNow
    [System.IO.File]::AppendAllText($ConsoleLog, "=== $Label START $($StartedAt.ToString('o')) ===`r`n", [Text.UTF8Encoding]::new($false))
    if (-not $Process.Start()) { throw "$Label did not start." }
    $ProcessStarted = $true
    $StdoutTask = $Process.StandardOutput.ReadToEndAsync()
    $StderrTask = $Process.StandardError.ReadToEndAsync()
    $Deadline = $StartedAt.AddSeconds($TimeoutSeconds)
    $TimedOut = $false
    while (-not $Process.WaitForExit(500)) {
        if ($CapturePackageOwnership) { Capture-WackOwnedObjects }
        if ([DateTimeOffset]::UtcNow -ge $Deadline) { $TimedOut = $true; break }
    }
    if ($TimedOut) {
        if ($CapturePackageOwnership) { Capture-WackOwnedObjects }
        $PreKillProcessTable = @(Get-CimInstance -ClassName Win32_Process -OperationTimeoutSec 5 -ErrorAction Stop)
        $CapturedDescendants = @(Get-ProcessDescendants -RootProcessId $Process.Id -ProcessTable $PreKillProcessTable)
        $FailSafeCapturedDescendants = $CapturedDescendants
        $AppCertProcessId = $Process.Id
        try { $Process.Kill($true) } catch { }
        $TreeStopped = $Process.WaitForExit(30000)
        Stop-ExactCapturedProcesses -CapturedProcesses $CapturedDescendants
        $OutputTasks = [Threading.Tasks.Task[]]@($StdoutTask, $StderrTask)
        $OutputClosed = [Threading.Tasks.Task]::WaitAll($OutputTasks, 30000)
        $TimedOutOutput = if ($OutputClosed) { $StdoutTask.GetAwaiter().GetResult() + $StderrTask.GetAwaiter().GetResult() } else { "[AppCert output pipes did not close after process-tree termination.]" }
        [System.IO.File]::AppendAllText($ConsoleLog, $TimedOutOutput + "`r`n=== $Label HARD TIMEOUT ===`r`n", [Text.UTF8Encoding]::new($false))
        if (-not $TreeStopped) { throw "$Label timed out and its process tree could not be terminated." }
        Assert-AppCertTreeExited -RootProcessId $AppCertProcessId -CapturedDescendants $CapturedDescendants
        if (-not $OutputClosed) { throw "$Label timed out; its process exited but descendant output handles remained open." }
        throw "$Label exceeded its hard timeout of $TimeoutSeconds seconds; its process tree was terminated."
    }
    if ($CapturePackageOwnership) { Capture-WackOwnedObjects }
    $PostExitProcessTable = @(Get-CimInstance -ClassName Win32_Process -OperationTimeoutSec 5 -ErrorAction Stop)
    $PostExitDescendants = @(Get-ProcessDescendants -RootProcessId $Process.Id -ProcessTable $PostExitProcessTable)
    $FailSafeCapturedDescendants = $PostExitDescendants
    $OutputTasks = [Threading.Tasks.Task[]]@($StdoutTask, $StderrTask)
    if (-not [Threading.Tasks.Task]::WaitAll($OutputTasks, 30000)) {
        Stop-ExactCapturedProcesses -CapturedProcesses $PostExitDescendants
        Assert-AppCertTreeExited -RootProcessId $Process.Id -CapturedDescendants $PostExitDescendants
        throw "$Label exited but its output pipes did not close within the hard drain timeout."
    }
    $Output = $StdoutTask.GetAwaiter().GetResult() + $StderrTask.GetAwaiter().GetResult()
    $FinishedAt = [DateTimeOffset]::UtcNow
    $ExitCode = $Process.ExitCode
    [System.IO.File]::AppendAllText($ConsoleLog, $Output + "`r`n=== $Label END $($FinishedAt.ToString('o')) EXIT $ExitCode ===`r`n", [Text.UTF8Encoding]::new($false))
    Write-Host "$Label exited $ExitCode after $([math]::Round(($FinishedAt - $StartedAt).TotalSeconds, 1)) seconds."
    return [pscustomobject]@{
        exitCode = $ExitCode
        startedAt = $StartedAt
        finishedAt = $FinishedAt
    }
    } finally {
        $FailSafeErrors = [Collections.Generic.List[string]]::new()
        if ($ProcessStarted) {
            $RootStillRunning = $false
            try { $RootStillRunning = -not $Process.HasExited } catch { $FailSafeErrors.Add($_.Exception.Message) }
            if ($RootStillRunning) {
                try {
                    $FailSafeTable = @(Get-CimInstance -ClassName Win32_Process -OperationTimeoutSec 5 -ErrorAction Stop)
                    $FailSafeCapturedDescendants = @(Get-ProcessDescendants -RootProcessId $Process.Id -ProcessTable $FailSafeTable)
                } catch { $FailSafeErrors.Add($_.Exception.Message) }
                try {
                    $Process.Kill($true)
                    if (-not $Process.WaitForExit(30000)) { throw "AppCert root process did not exit." }
                } catch { $FailSafeErrors.Add($_.Exception.Message) }
            }
            if ($FailSafeCapturedDescendants.Count -ne 0) {
                try {
                    Stop-ExactCapturedProcesses -CapturedProcesses $FailSafeCapturedDescendants
                    Assert-AppCertTreeExited -RootProcessId $Process.Id -CapturedDescendants $FailSafeCapturedDescendants
                } catch { $FailSafeErrors.Add($_.Exception.Message) }
            }
        }
        try { $Process.Dispose() } catch { $FailSafeErrors.Add($_.Exception.Message) }
        if ($FailSafeErrors.Count -ne 0) { throw "$Label fail-safe process cleanup failed: $($FailSafeErrors -join '; ')" }
    }
}

$PackageHashBefore = Assert-CandidateBytes "start"
$SourceCommit = (& git rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0) { throw "git rev-parse HEAD returned $LASTEXITCODE." }
if ($SourceCommit -ne $Candidate.sourceCommit) { throw "WACK checkout commit differs from candidate source commit." }
if ((Get-FileHash -Algorithm SHA256 -LiteralPath $CerPath).Hash.ToLowerInvariant() -ne $Candidate.certificateSha256) { throw "WACK CER differs from candidate manifest." }
$Certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($CerPath)
if ($Certificate.Thumbprint -ne $Candidate.certificateThumbprint -or $Certificate.Subject -cne $ExpectedTechnicalPublisher) {
    throw "WACK CER does not match the Partner Center technical Publisher."
}

$PreexistingPackages = @(Get-AppxPackage -Name $Candidate.packageIdentity -ErrorAction SilentlyContinue)
if ($PreexistingPackages.Count -ne 0) { throw "Fail-closed: WACK will not uninstall a preexisting package with this identity." }
$PreexistingProcesses = @(Get-Process -Name "QuantScenarioStudio", "AegisBackend" -ErrorAction SilentlyContinue)
if ($PreexistingProcesses.Count -ne 0) { throw "Fail-closed: WACK will not stop preexisting same-named processes." }
$PackagesRoot = Join-Path $env:LOCALAPPDATA "Packages"
$FamilyPrefix = "$($Candidate.packageIdentity)_"
$PreexistingFamilyRoots = @(
    Get-ChildItem -LiteralPath $PackagesRoot -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name.StartsWith($FamilyPrefix, [StringComparison]::OrdinalIgnoreCase) }
)
if ($PreexistingFamilyRoots.Count -ne 0) { throw "Fail-closed: WACK found a preexisting LocalState/PFN root for this identity." }
$TrustedPeoplePath = "Cert:\CurrentUser\TrustedPeople\$($Certificate.Thumbprint)"
if (Test-Path -LiteralPath $TrustedPeoplePath) { throw "Fail-closed: the exact WACK certificate was already trusted." }
$WindowsTempRoot = [IO.Path]::GetFullPath((Join-Path $env:WINDIR "Temp")).TrimEnd("\")
$PreexistingAppCertRoots = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$PreexistingAppCertProcesses = @(
    Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($AppCert)) -ErrorAction SilentlyContinue |
        Where-Object {
            try { [IO.Path]::GetFullPath($_.Path).Equals($AppCert, [StringComparison]::OrdinalIgnoreCase) }
            catch { $false }
        }
)
if ($PreexistingAppCertProcesses.Count -ne 0) { throw "Fail-closed: the approved AppCert executable is already running on this dedicated runner." }
foreach ($ExistingRoot in @(Get-ChildItem -LiteralPath $WindowsTempRoot -Directory -Force -Filter "appcert_*" -ErrorAction SilentlyContinue)) {
    $ExactExistingRoot = [IO.Path]::GetFullPath($ExistingRoot.FullName).TrimEnd("\")
    [void]$PreexistingAppCertRoots.Add($ExactExistingRoot)
    if (($ExistingRoot.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
        $StaleCandidateRoots = @(Get-ChildItem -LiteralPath $ExactExistingRoot -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name.StartsWith("$($Candidate.packageIdentity)_", [StringComparison]::Ordinal) })
        if ($StaleCandidateRoots.Count -ne 0) { throw "Fail-closed: a candidate-matching AppCert root preexisted this WACK run." }
    }
}

$ReportRoot = Join-Path $ProjectRoot "artifacts\wack\round-$WackRound"
if (Test-Path -LiteralPath $ReportRoot) {
    $OldReportRoot = Get-Item -LiteralPath $ReportRoot -Force
    $OldReportReparse = @(Get-ChildItem -LiteralPath $ReportRoot -Force -Recurse -ErrorAction Stop | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 })
    if (($OldReportRoot.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $OldReportReparse.Count -ne 0) { throw "Refusing to reset a reparse-point WACK report tree." }
    Remove-Item -LiteralPath $ReportRoot -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $ReportRoot | Out-Null
$Report = Join-Path $ReportRoot "appcert-report.xml"
$PowerShellTranscript = Join-Path $ReportRoot "powershell-transcript.log"
$AppCertLog = Join-Path $ReportRoot "appcert-console.log"
$RunStartedAt = [DateTimeOffset]::UtcNow
$CertificateImportAttempted = $false
$TranscriptStarted = $false
$CreatedPackages = @{}
$CreatedFamilyRoots = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$CreatedAppCertRoots = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$OwnedProcesses = @{}
$WackReportPackageFullName = $null
$WackReportInstallLocation = $null
$PrimaryFailure = $null

function Test-TreeHasReparsePoint([string]$Root) {
    $RootItem = Get-Item -LiteralPath $Root -Force -ErrorAction Stop
    if (($RootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $true }
    return @(
        Get-ChildItem -LiteralPath $Root -Force -Recurse -ErrorAction Stop |
            Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 }
    ).Count -gt 0
}

function Register-FreshAppCertRoot($RootItem) {
    $AppCertRoot = [IO.Path]::GetFullPath([string]$RootItem.FullName).TrimEnd("\")
    $Parent = [IO.Directory]::GetParent($AppCertRoot).FullName.TrimEnd("\")
    $Leaf = [IO.Path]::GetFileName($AppCertRoot)
    if ($Parent -cne $WindowsTempRoot -or $Leaf -cnotmatch '^appcert_[A-Za-z0-9._-]+$' -or
        $PreexistingAppCertRoots.Contains($AppCertRoot)) { throw "Fresh AppCert root escaped its exact new Windows Temp boundary." }
    if (($RootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        [DateTimeOffset]$RootItem.CreationTimeUtc -lt $RunStartedAt.AddSeconds(-2) -or
        [DateTimeOffset]$RootItem.LastWriteTimeUtc -lt $RunStartedAt.AddSeconds(-2)) {
        throw "Fresh AppCert root is stale or is a reparse point."
    }
    [void]$CreatedAppCertRoots.Add($AppCertRoot)
    return $AppCertRoot
}

function Register-AppCertInstallLocation([string]$PackageFullName, [string]$RawInstallLocation) {
    $InstallLocation = [IO.Path]::GetFullPath($RawInstallLocation).TrimEnd("\")
    $AppCertRoot = [IO.Directory]::GetParent($InstallLocation).FullName.TrimEnd("\")
    $Parent = [IO.Directory]::GetParent($AppCertRoot).FullName.TrimEnd("\")
    $AppCertLeaf = [IO.Path]::GetFileName($AppCertRoot)
    if ($Parent -cne $WindowsTempRoot -or $AppCertLeaf -cnotmatch '^appcert_[A-Za-z0-9._-]+$' -or
        [IO.Path]::GetFileName($InstallLocation) -cne $PackageFullName -or
        $PreexistingAppCertRoots.Contains($AppCertRoot)) {
        throw "AppCert ownership did not resolve to a new exact Windows Temp appcert root for this run."
    }
    if (Test-Path -LiteralPath $AppCertRoot) {
        $RootItem = Get-Item -LiteralPath $AppCertRoot -Force
        if (($RootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            [DateTimeOffset]$RootItem.CreationTimeUtc -lt $RunStartedAt.AddSeconds(-2) -or
            [DateTimeOffset]$RootItem.LastWriteTimeUtc -lt $RunStartedAt.AddSeconds(-2)) {
            throw "AppCert ownership root is stale or is a reparse point."
        }
    }
    [void]$CreatedAppCertRoots.Add($AppCertRoot)
    $CreatedPackages["$PackageFullName|$($InstallLocation.ToLowerInvariant())"] = [pscustomobject]@{
        packageFullName = $PackageFullName
        packageFamilyName = ""
        installLocation = $InstallLocation
    }
    return $InstallLocation
}

function Capture-FreshAppCertRoots {
    foreach ($RootItem in @(Get-ChildItem -LiteralPath $WindowsTempRoot -Directory -Force -Filter "appcert_*" -ErrorAction SilentlyContinue)) {
        $AppCertRoot = [IO.Path]::GetFullPath($RootItem.FullName).TrimEnd("\")
        if ($PreexistingAppCertRoots.Contains($AppCertRoot)) { continue }
        # Register the fresh exact root before expecting a package manifest. If
        # AppCert fails during extraction, the outer finally block still owns and
        # cleans this new direct Windows Temp root instead of leaking a partial
        # appcert_* tree into the next run.
        $AppCertRoot = Register-FreshAppCertRoot $RootItem
        foreach ($InstallItem in @(Get-ChildItem -LiteralPath $AppCertRoot -Directory -Force -ErrorAction SilentlyContinue)) {
            $PackageFullName = [string]$InstallItem.Name
            if ($PackageFullName -cnotmatch "^$([regex]::Escape($Candidate.packageIdentity))_$([regex]::Escape([string]$Candidate.packageVersion))_x64__") { continue }
            $ManifestFile = Join-Path $InstallItem.FullName "AppxManifest.xml"
            if (-not (Test-Path -LiteralPath $ManifestFile -PathType Leaf)) { continue }
            $ManifestItem = Get-Item -LiteralPath $ManifestFile -Force
            if (($RootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                ($InstallItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                ($ManifestItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "A candidate-matching AppCert ownership path contains a reparse point."
            }
            [xml]$PackageManifest = Get-Content -Raw -LiteralPath $ManifestFile
            $ManifestIdentity = $PackageManifest.SelectSingleNode("/*[local-name()='Package']/*[local-name()='Identity']")
            if (-not $ManifestIdentity -or $ManifestIdentity.GetAttribute("Name") -cne $Candidate.packageIdentity -or
                $ManifestIdentity.GetAttribute("Publisher") -cne $ExpectedTechnicalPublisher -or
                $ManifestIdentity.GetAttribute("Version") -cne [string]$Candidate.packageVersion -or
                $ManifestIdentity.GetAttribute("ProcessorArchitecture") -cne "x64") { continue }
            [void](Register-AppCertInstallLocation -PackageFullName $PackageFullName -RawInstallLocation $InstallItem.FullName)
        }
    }
}

function Capture-WackOwnedObjects {
    Capture-FreshAppCertRoots
    foreach ($Package in @(Get-AppxPackage -Name $Candidate.packageIdentity -ErrorAction SilentlyContinue)) {
        if ($Package.Name -cne $Candidate.packageIdentity -or $Package.Publisher -cne $ExpectedTechnicalPublisher) { continue }
        $PackageFullName = [string]$Package.PackageFullName
        $PackageFamilyName = [string]$Package.PackageFamilyName
        $RawInstallLocation = [string]$Package.InstallLocation
        if ([string]::IsNullOrWhiteSpace($PackageFullName) -or [string]::IsNullOrWhiteSpace($PackageFamilyName) -or
            [string]::IsNullOrWhiteSpace($RawInstallLocation) -or
            -not $PackageFullName.StartsWith("$($Candidate.packageIdentity)_", [StringComparison]::Ordinal) -or
            -not $PackageFamilyName.StartsWith($FamilyPrefix, [StringComparison]::Ordinal)) { continue }
        $InstallLocation = [IO.Path]::GetFullPath($RawInstallLocation).TrimEnd("\")
        $CreatedPackages["$PackageFullName|$($InstallLocation.ToLowerInvariant())"] = [pscustomobject]@{
            packageFullName = $PackageFullName
            packageFamilyName = $PackageFamilyName
            installLocation = $InstallLocation
        }
        [void]$CreatedFamilyRoots.Add((Join-Path $PackagesRoot $PackageFamilyName))
    }
    foreach ($Process in @(Get-Process -Name "QuantScenarioStudio", "AegisBackend" -ErrorAction SilentlyContinue)) {
        try {
            $ProcessPath = [IO.Path]::GetFullPath($Process.Path)
            $CreationTicks = $Process.StartTime.ToUniversalTime().Ticks
        } catch { continue }
        foreach ($PackageRecord in @($CreatedPackages.Values)) {
            if (Test-PathWithin $ProcessPath $PackageRecord.installLocation) {
                $OwnedProcesses["$($Process.Id)|$CreationTicks"] = [pscustomobject]@{
                    processId = [int]$Process.Id
                    executablePath = $ProcessPath
                    creationTimeUtcTicks = [long]$CreationTicks
                }
                break
            }
        }
    }
}

function Capture-WackReportOwnedLocation {
    [xml]$WackXml = Get-Content -Raw -LiteralPath $Report
    $Programs = @(
        $WackXml.SelectNodes("//*[local-name()='Installed_Programs']/*[local-name()='Program']") |
            Where-Object {
                $_.GetAttribute("Source") -ceq "AppxPackage" -and
                $_.GetAttribute("Name") -ceq $Candidate.packageIdentity -and
                $_.GetAttribute("Publisher") -ceq $ExpectedTechnicalPublisher
            }
    )
    if ($Programs.Count -ne 1) { throw "Fresh WACK report must identify exactly one tested AppxPackage program." }
    $EmbeddedManifests = @($Programs[0].SelectNodes(".//*[local-name()='PackageManifest']"))
    $EmbeddedIdentities = @($Programs[0].SelectNodes(".//*[local-name()='PackageManifest']//*[local-name()='Identity']"))
    $EmbeddedPublisherDisplayNames = @($Programs[0].SelectNodes(".//*[local-name()='PackageManifest']//*[local-name()='Properties']/*[local-name()='PublisherDisplayName']"))
    if ($EmbeddedManifests.Count -ne 1 -or $EmbeddedIdentities.Count -ne 1 -or
        $EmbeddedPublisherDisplayNames.Count -ne 1 -or $EmbeddedPublisherDisplayNames[0].InnerText -cne "LAI ZEYU") { throw "Fresh WACK report package identity/visible-publisher tree is missing or ambiguous." }
    $PackageFullName = $EmbeddedManifests[0].GetAttribute("PackageFullName")
    $EmbeddedIdentity = $EmbeddedIdentities[0]
    $RawInstallLocation = $Programs[0].GetAttribute("RootDirPath")
    if ($PackageFullName -cnotmatch "^$([regex]::Escape($Candidate.packageIdentity))_" -or
        $EmbeddedIdentity.GetAttribute("Name") -cne $Candidate.packageIdentity -or
        $EmbeddedIdentity.GetAttribute("Publisher") -cne $ExpectedTechnicalPublisher -or
        [string]::IsNullOrWhiteSpace($RawInstallLocation)) { throw "Fresh WACK report package identity differs from the candidate." }
    $InstallLocation = Register-AppCertInstallLocation -PackageFullName $PackageFullName -RawInstallLocation $RawInstallLocation
    $script:WackReportPackageFullName = $PackageFullName
    $script:WackReportInstallLocation = $InstallLocation
    Capture-WackOwnedObjects
}

function Remove-WackOwnedObjects {
    param([Parameter(Mandatory = $true)][Collections.Generic.List[string]]$Errors)
    try { Capture-WackOwnedObjects } catch { $Errors.Add("capture owned WACK objects: $($_.Exception.Message)") }

    foreach ($Record in @($OwnedProcesses.Values)) {
        try {
            $Owned = Get-Process -Id ([int]$Record.processId) -ErrorAction SilentlyContinue
            if (-not $Owned) { continue }
            $CurrentPath = [IO.Path]::GetFullPath($Owned.Path)
            $CurrentTicks = $Owned.StartTime.ToUniversalTime().Ticks
            if (-not $CurrentPath.Equals([string]$Record.executablePath, [StringComparison]::OrdinalIgnoreCase) -or
                $CurrentTicks -ne [long]$Record.creationTimeUtcTicks) {
                continue
            }
            Stop-Process -Id ([int]$Record.processId) -Force -ErrorAction Stop
            for ($Attempt = 0; $Attempt -lt 100; $Attempt++) {
                $Current = Get-Process -Id ([int]$Record.processId) -ErrorAction SilentlyContinue
                if (-not $Current -or $Current.StartTime.ToUniversalTime().Ticks -ne [long]$Record.creationTimeUtcTicks) { break }
                Start-Sleep -Milliseconds 100
            }
            $Remaining = Get-Process -Id ([int]$Record.processId) -ErrorAction SilentlyContinue
            if ($Remaining -and $Remaining.StartTime.ToUniversalTime().Ticks -eq [long]$Record.creationTimeUtcTicks) { throw "Owned WACK process remained after cleanup." }
        } catch { $Errors.Add("process $($Record.processId): $($_.Exception.Message)") }
    }

    $RemovedPackageNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($PackageRecord in @($CreatedPackages.Values)) {
        $PackageFullName = [string]$PackageRecord.packageFullName
        if (-not $RemovedPackageNames.Add($PackageFullName)) { continue }
        try {
            $Exact = @(Get-AppxPackage -Name $Candidate.packageIdentity -ErrorAction SilentlyContinue | Where-Object { $_.PackageFullName -ceq $PackageFullName -and $_.Publisher -ceq $ExpectedTechnicalPublisher })
            if ($Exact.Count -gt 1) { throw "More than one exact run-owned package record exists." }
            if ($Exact.Count -eq 1) { Remove-AppxPackage -Package $PackageFullName -ErrorAction Stop }
            for ($Attempt = 0; $Attempt -lt 60; $Attempt++) {
                if (@(Get-AppxPackage -Name $Candidate.packageIdentity -ErrorAction SilentlyContinue | Where-Object PackageFullName -ceq $PackageFullName).Count -eq 0) { break }
                Start-Sleep -Milliseconds 500
            }
            if (@(Get-AppxPackage -Name $Candidate.packageIdentity -ErrorAction SilentlyContinue | Where-Object PackageFullName -ceq $PackageFullName).Count -ne 0) { throw "Exact WACK package remained installed." }
        } catch { $Errors.Add("package $PackageFullName`: $($_.Exception.Message)") }
    }

    foreach ($FamilyRoot in $CreatedFamilyRoots) {
        try {
            $ExactFamilyRoot = [IO.Path]::GetFullPath($FamilyRoot).TrimEnd("\")
            $ExpectedPrefix = [IO.Path]::GetFullPath($PackagesRoot).TrimEnd("\") + "\"
            $Leaf = [IO.Path]::GetFileName($ExactFamilyRoot)
            if (-not $ExactFamilyRoot.StartsWith($ExpectedPrefix, [StringComparison]::OrdinalIgnoreCase) -or
                -not $Leaf.StartsWith($FamilyPrefix, [StringComparison]::Ordinal)) { throw "PFN root escaped the exact candidate family boundary." }
            if (@(Get-AppxPackage -Name $Candidate.packageIdentity -ErrorAction SilentlyContinue | Where-Object PackageFamilyName -ceq $Leaf).Count -ne 0) { throw "Exact package family remains installed." }
            if (Test-Path -LiteralPath $ExactFamilyRoot) {
                if (Test-TreeHasReparsePoint $ExactFamilyRoot) { throw "PFN cleanup tree contains a reparse point." }
                Remove-Item -LiteralPath $ExactFamilyRoot -Recurse -Force -ErrorAction Stop
            }
            if (Test-Path -LiteralPath $ExactFamilyRoot) { throw "Exact PFN root remained after cleanup." }
        } catch { $Errors.Add("PFN root $FamilyRoot`: $($_.Exception.Message)") }
    }

    foreach ($AppCertRoot in $CreatedAppCertRoots) {
        try {
            $ExactRoot = [IO.Path]::GetFullPath($AppCertRoot).TrimEnd("\")
            $Parent = [IO.Directory]::GetParent($ExactRoot).FullName.TrimEnd("\")
            $Leaf = [IO.Path]::GetFileName($ExactRoot)
            if ($Parent -cne $WindowsTempRoot -or $Leaf -cnotmatch '^appcert_[A-Za-z0-9._-]+$' -or
                $PreexistingAppCertRoots.Contains($ExactRoot)) { throw "AppCert cleanup root escaped its exact new Windows Temp boundary." }
            if (Test-Path -LiteralPath $ExactRoot) {
                if (Test-TreeHasReparsePoint $ExactRoot) { throw "AppCert cleanup tree contains a reparse point." }
                Remove-Item -LiteralPath $ExactRoot -Recurse -Force -ErrorAction Stop
            }
            if (Test-Path -LiteralPath $ExactRoot) { throw "Exact AppCert root remained after cleanup." }
        } catch { $Errors.Add("AppCert root $AppCertRoot`: $($_.Exception.Message)") }
    }
}

try {
    $CertificateImportAttempted = $true
    $Imported = Import-Certificate -FilePath $CerPath -CertStoreLocation "Cert:\CurrentUser\TrustedPeople"
    if ($Imported.Thumbprint -ne $Certificate.Thumbprint -or $Imported.Subject -cne $ExpectedTechnicalPublisher) { throw "WACK certificate import mismatch." }
    $Signature = Get-AuthenticodeSignature -LiteralPath $PackagePath
    if ($Signature.Status -ne "Valid" -or $Signature.SignerCertificate.Thumbprint -ne $Certificate.Thumbprint -or $Signature.SignerCertificate.Subject -cne $ExpectedTechnicalPublisher) {
        throw "WACK package signature does not match the technical Publisher certificate."
    }
    if (-not (Test-Path -LiteralPath $AppCert)) { throw "Windows App Certification Kit appcert.exe was not found." }
    if ((Test-Path $Report) -or (Test-Path $PowerShellTranscript) -or (Test-Path $AppCertLog)) { throw "Stale WACK evidence survived the clean report-root reset." }

    Start-Transcript -Path $PowerShellTranscript -Force | Out-Null
    $TranscriptStarted = $true
    $Reset = Invoke-BoundedAppCert -Label "appcert reset" -Arguments @("reset") -TimeoutSeconds 300 -ConsoleLog $AppCertLog
    if ($Reset.exitCode -ne 0) { throw "appcert reset returned $($Reset.exitCode)." }
    $Test = Invoke-BoundedAppCert -Label "appcert test" -Arguments @("test", "-appxpackagepath", $PackagePath, "-reportoutputpath", $Report) -TimeoutSeconds 3600 -ConsoleLog $AppCertLog -CapturePackageOwnership
    if ($Test.exitCode -ne 0) { throw "appcert test returned $($Test.exitCode)." }
    Stop-Transcript | Out-Null
    $TranscriptStarted = $false
    $RunFinishedAt = [DateTimeOffset]::UtcNow

    foreach ($FreshFile in @($Report, $PowerShellTranscript, $AppCertLog)) {
        if (-not (Test-Path -LiteralPath $FreshFile) -or (Get-Item -LiteralPath $FreshFile).Length -le 0) { throw "WACK evidence is missing or empty: $FreshFile" }
        $FreshItem = Get-Item -LiteralPath $FreshFile -Force
        if (($FreshItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "WACK evidence file is a reparse point: $FreshFile" }
        $Written = [DateTimeOffset]$FreshItem.LastWriteTimeUtc
        if ($Written -lt $RunStartedAt.AddSeconds(-2) -or $Written -gt $RunFinishedAt.AddMinutes(1)) { throw "WACK evidence is stale or has an impossible timestamp: $FreshFile" }
    }

    $ResultValues = @(Read-AegisCompleteWackReport $Report)
    Capture-WackReportOwnedLocation

    # AppCert may intentionally leave its package or app process behind. Clean
    # only objects tied to the exact PackageFullName and InstallLocation that
    # this invocation was observed creating.
    $StageCleanupErrors = [Collections.Generic.List[string]]::new()
    Remove-WackOwnedObjects -Errors $StageCleanupErrors
    if ($StageCleanupErrors.Count -ne 0) { throw "WACK runtime cleanup failed: $($StageCleanupErrors -join '; ')" }

    for ($Attempt = 0; $Attempt -lt 120; $Attempt++) {
        Capture-WackOwnedObjects
        $PostProcesses = @(Get-Process -Name "QuantScenarioStudio", "AegisBackend" -ErrorAction SilentlyContinue)
        $PostPackages = @(Get-AppxPackage -Name $Candidate.packageIdentity -ErrorAction SilentlyContinue)
        $PostFamilyRoots = @(Get-ChildItem -LiteralPath $PackagesRoot -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name.StartsWith($FamilyPrefix, [StringComparison]::OrdinalIgnoreCase) })
        $PostAppCertRoots = @($CreatedAppCertRoots | Where-Object { Test-Path -LiteralPath $_ })
        if ($PostProcesses.Count -eq 0 -and $PostPackages.Count -eq 0 -and $PostFamilyRoots.Count -eq 0 -and $PostAppCertRoots.Count -eq 0) { break }
        Start-Sleep -Milliseconds 500
    }
    Capture-WackOwnedObjects
    $PostProcesses = @(Get-Process -Name "QuantScenarioStudio", "AegisBackend" -ErrorAction SilentlyContinue)
    $PostPackages = @(Get-AppxPackage -Name $Candidate.packageIdentity -ErrorAction SilentlyContinue)
    $PostFamilyRoots = @(Get-ChildItem -LiteralPath $PackagesRoot -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name.StartsWith($FamilyPrefix, [StringComparison]::OrdinalIgnoreCase) })
    $PostAppCertRoots = @($CreatedAppCertRoots | Where-Object { Test-Path -LiteralPath $_ })
    if ($PostProcesses.Count -ne 0 -or $PostPackages.Count -ne 0 -or $PostFamilyRoots.Count -ne 0 -or $PostAppCertRoots.Count -ne 0) {
        throw "WACK left runtime or exact AppCert-root residue. Cleanup is limited to path-and-creation-time-bound processes and exact roots captured from this run."
    }

    $PackageHashAfter = Assert-CandidateBytes "completion"
    [ordered]@{
        schemaVersion = 3
        wackRound = $WackRound
        product = $Candidate.product
        author = $Candidate.author
        technicalPublisher = $ExpectedTechnicalPublisher
        sourceCommit = $Candidate.sourceCommit
        packageSha256Before = $PackageHashBefore
        packageSha256After = $PackageHashAfter
        submissionPackageSha256 = $Candidate.submissionPackageSha256
        payloadTreeSha256 = $Candidate.payloadTreeSha256
        submissionPayloadEquivalent = $true
        appcertResetExitCode = $Reset.exitCode
        appcertTestExitCode = $Test.exitCode
        appcertReset = "PASS"
        appcertTest = "PASS"
        partialRun = $false
        wackPackageFullName = $WackReportPackageFullName
        wackInstallLocation = $WackReportInstallLocation
        report = "appcert-report.xml"
        reportSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $Report).Hash.ToLowerInvariant()
        powershellTranscriptSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $PowerShellTranscript).Hash.ToLowerInvariant()
        appcertConsoleSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $AppCertLog).Hash.ToLowerInvariant()
        resultCount = $ResultValues.Count
        overallResults = @($ResultValues)
        hardTimeoutEnforced = $true
        interactiveSessionId = $CurrentSessionId
        elevatedAdministrator = [bool]$RunnerPolicy.elevatedAdministrator
        wackFileVersion = [string]$RunnerPolicy.fileVersion
        noRuntimeResidue = $true
        capturedAt = [DateTimeOffset]::UtcNow.ToString("o")
    } | ConvertTo-Json -Depth 4 | Set-Content -Encoding utf8 (Join-Path $ReportRoot "wack-summary.json")
} catch {
    $PrimaryFailure = $_.Exception
} finally {
    $FinalErrors = [Collections.Generic.List[string]]::new()
    if ($PrimaryFailure) { $FinalErrors.Add("verification: $($PrimaryFailure.Message)") }
    if ($TranscriptStarted) {
        try { Stop-Transcript | Out-Null } catch { $FinalErrors.Add("transcript: $($_.Exception.Message)") }
    }
    Remove-WackOwnedObjects -Errors $FinalErrors
    if ($CertificateImportAttempted) {
        try {
            & scripts\windows\remove-development-certificate.ps1 -Thumbprint $Certificate.Thumbprint -StoreLocations @("CurrentUser\TrustedPeople")
        } catch { $FinalErrors.Add("certificate: $($_.Exception.Message)") }
    }
    if ($FinalErrors.Count -ne 0) { throw "WACK verification/cleanup failures: $($FinalErrors -join ' | ')" }
}

Write-Host "WACK round $WackRound strict gate passed on unchanged temporary QA bytes $PackageHashBefore and payload-equivalent unsigned Store submission $($Candidate.submissionPackageSha256)."
