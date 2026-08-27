[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$WorkingRoot
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
if (-not $IsWindows) { throw "SSL.com CKA setup requires Windows." }
if ($env:AEGIS_TRUSTED_GITHUB_BUILD -cne "1") { throw "Refusing CKA setup outside the protected trusted-release workflow." }
if ($env:GITHUB_RUN_ID -cnotmatch "^[0-9]+$" -or $env:GITHUB_RUN_ATTEMPT -cnotmatch "^[0-9]+$") { throw "CKA setup requires a concrete GitHub run identity." }
foreach ($Name in @("SSL_ESIGNER_USERNAME", "SSL_ESIGNER_PASSWORD", "SSL_ESIGNER_TOTP_SECRET")) {
    $Value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($Value)) { throw "Trusted release requires $Name." }
    Write-Output "::add-mask::$Value"
}
if (-not $env:RUNNER_TEMP) { throw "RUNNER_TEMP is required." }
$RunnerPrefix = [IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd("\") + "\"
$Root = [IO.Path]::GetFullPath($WorkingRoot)
if (-not $Root.StartsWith($RunnerPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw "CKA working root must remain under RUNNER_TEMP." }
if (Test-Path -LiteralPath $Root) { throw "CKA working root must not preexist." }
$AllowedNames = @("LAI ZEYU", "来泽宇")
$PreexistingMyThumbprints = @(
    Get-ChildItem Cert:\CurrentUser\My |
        ForEach-Object { [string]$_.Thumbprint } |
        Where-Object { $_ -cmatch "^[0-9A-F]{40}$" } |
        Sort-Object -Unique
)
$PreexistingMySet = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($Thumbprint in $PreexistingMyThumbprints) { [void]$PreexistingMySet.Add($Thumbprint) }
$PreexistingPermittedSigners = @(
    Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert |
        Where-Object { $AllowedNames -ccontains $_.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false) }
)
if ($PreexistingPermittedSigners.Count -ne 0) { throw "Fail-closed: a permitted-name code-signing certificate already exists before CKA setup." }
$StateRoot = Join-Path $env:APPDATA "eSignerCKA"
if (Test-Path -LiteralPath $StateRoot) { throw "Fail-closed: an eSignerCKA user-state directory already exists on this runner." }
New-Item -ItemType Directory -Path $Root | Out-Null

function Protect-CkaText([string]$Text) {
    $Protected = [string]$Text
    foreach ($Secret in @($env:SSL_ESIGNER_USERNAME, $env:SSL_ESIGNER_PASSWORD, $env:SSL_ESIGNER_TOTP_SECRET)) {
        if ($Secret) { $Protected = $Protected.Replace($Secret, "[REDACTED]") }
    }
    return $Protected
}

function Invoke-CkaTool {
    param(
        [string]$FileName,
        [string[]]$Arguments,
        [int]$TimeoutSeconds = 180,
        [int[]]$AllowedExitCodes = @(0)
    )
    $Info = [Diagnostics.ProcessStartInfo]::new()
    $Info.FileName = $FileName
    $Info.UseShellExecute = $false
    $Info.CreateNoWindow = $true
    $Info.RedirectStandardOutput = $true
    $Info.RedirectStandardError = $true
    foreach ($Argument in $Arguments) { [void]$Info.ArgumentList.Add($Argument) }
    $Process = [Diagnostics.Process]::new()
    $Process.StartInfo = $Info
    $Started = $false
    $Stdout = $null
    $Stderr = $null
    $PrimaryFailure = $null
    try {
        if (-not $Process.Start()) { throw "SSL.com CKA helper did not start." }
        $Started = $true
        $Stdout = $Process.StandardOutput.ReadToEndAsync()
        $Stderr = $Process.StandardError.ReadToEndAsync()
        if (-not $Process.WaitForExit($TimeoutSeconds * 1000)) { throw "SSL.com CKA helper exceeded its hard timeout." }
        $OutputTasks = [Threading.Tasks.Task[]]@($Stdout, $Stderr)
        if (-not [Threading.Tasks.Task]::WaitAll($OutputTasks, 30000)) { throw "SSL.com CKA helper output did not close within its hard timeout." }
        $Message = Protect-CkaText ($Stdout.GetAwaiter().GetResult() + $Stderr.GetAwaiter().GetResult())
        if ($Process.ExitCode -notin $AllowedExitCodes) { throw "SSL.com CKA helper returned $($Process.ExitCode): $Message" }
    } catch {
        $PrimaryFailure = $_.Exception
    } finally {
        $CleanupErrors = [Collections.Generic.List[string]]::new()
        if ($Started) {
            try {
                if (-not $Process.HasExited) {
                    $Process.Kill($true)
                    if (-not $Process.WaitForExit(30000)) { throw "SSL.com CKA helper process tree remained during fail-safe cleanup." }
                }
            } catch { $CleanupErrors.Add($_.Exception.Message) }
        }
        if ($Stdout -and $Stderr) {
            try {
                $OutputTasks = [Threading.Tasks.Task[]]@($Stdout, $Stderr)
                if (-not [Threading.Tasks.Task]::WaitAll($OutputTasks, 30000)) { throw "SSL.com CKA helper output tasks remained during fail-safe cleanup." }
            } catch { $CleanupErrors.Add($_.Exception.Message) }
        }
        try { $Process.Dispose() } catch { $CleanupErrors.Add($_.Exception.Message) }
        if ($PrimaryFailure -or $CleanupErrors.Count -ne 0) {
            $Failures = [Collections.Generic.List[string]]::new()
            if ($PrimaryFailure) { $Failures.Add((Protect-CkaText $PrimaryFailure.Message)) }
            foreach ($CleanupError in $CleanupErrors) { $Failures.Add((Protect-CkaText $CleanupError)) }
            throw "SSL.com CKA helper failure: $($Failures -join ' | ')"
        }
    }
}

$Archive = Join-Path $Root "SSL.COM-eSigner-CKA_1.0.8.zip"
$Extracted = Join-Path $Root "download"
$InstallRoot = Join-Path $Root "installed"
$MasterKey = Join-Path $Root "master.key"
$UninstallerSha256 = ""
function Write-CkaOwnership {
    param([string[]]$OwnedSignerThumbprints = @(), [string]$SignerThumbprint = "")
    $CanonicalOwned = @($OwnedSignerThumbprints | Sort-Object -Unique)
    if (@($CanonicalOwned | Where-Object { $_ -cnotmatch "^[0-9A-F]{40}$" }).Count -ne 0 -or
        ($SignerThumbprint -and ($SignerThumbprint -cnotmatch "^[0-9A-F]{40}$" -or $SignerThumbprint -cnotin $CanonicalOwned))) {
        throw "Refusing to write an invalid CKA certificate ownership marker."
    }
    [ordered]@{
        schemaVersion = 4
        githubRunId = $env:GITHUB_RUN_ID
        githubRunAttempt = $env:GITHUB_RUN_ATTEMPT
        workingRoot = $Root
        installRoot = $InstallRoot
        stateRoot = $StateRoot
        uninstallerSha256 = $UninstallerSha256
        signerThumbprint = $SignerThumbprint
        preexistingMyThumbprints = @($PreexistingMyThumbprints)
        ownedSignerThumbprints = @($CanonicalOwned)
    } | ConvertTo-Json | Set-Content -Encoding utf8 (Join-Path $Root ".aegis-cka-owned.json")
}
Write-CkaOwnership
Invoke-WebRequest -Uri "https://github.com/SSLcom/eSignerCKA/releases/download/v1.0.8/SSL.COM-eSigner-CKA_1.0.8.zip" -OutFile $Archive
if ((Get-FileHash -Algorithm SHA256 -LiteralPath $Archive).Hash.ToLowerInvariant() -cne "c45bcd520a2a77acda150c12a1c233ca2408b3c10c2016b8d0dc8b9aefc0cadb") { throw "Pinned SSL.com CKA archive checksum mismatch." }
Expand-Archive -LiteralPath $Archive -DestinationPath $Extracted
$Installers = @(Get-ChildItem -LiteralPath $Extracted -File -Filter *.exe)
if ($Installers.Count -ne 1 -or (Get-FileHash -Algorithm SHA256 -LiteralPath $Installers[0].FullName).Hash.ToLowerInvariant() -cne "c750ec9befc423bed9c80cfb089d9e9f997898cf52f8499534093dd781bf9b53") { throw "Pinned SSL.com CKA installer is missing, ambiguous, or changed." }
New-Item -ItemType Directory -Path $InstallRoot | Out-Null
Invoke-CkaTool $Installers[0].FullName @("/CURRENTUSER", "/VERYSILENT", "/SUPPRESSMSGBOXES", "/DIR=$InstallRoot") 600
foreach ($Required in @("RegisterKSP.exe", "eSignerCSP.Config.exe", "eSignerCKATool.exe", "unins000.exe")) {
    if (-not (Test-Path -LiteralPath (Join-Path $InstallRoot $Required))) { throw "Installed SSL.com CKA is missing $Required." }
}
$Uninstaller = Get-Item -LiteralPath (Join-Path $InstallRoot "unins000.exe") -Force
if (($Uninstaller.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Installed SSL.com CKA uninstaller is a reparse point." }
$UninstallerSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $Uninstaller.FullName).Hash.ToLowerInvariant()
if ($UninstallerSha256 -cnotmatch '^[0-9a-f]{64}$') { throw "Installed SSL.com CKA uninstaller hash is invalid." }
Write-CkaOwnership

foreach ($Architecture in @("x86", "x64")) {
    $Redistributable = Join-Path $InstallRoot "setup\vc_redist.$Architecture.exe"
    if (-not (Test-Path -LiteralPath $Redistributable)) { throw "SSL.com CKA install is missing Microsoft's $Architecture VC++ runtime installer." }
    $RuntimeSignature = Get-AuthenticodeSignature -LiteralPath $Redistributable
    if ($RuntimeSignature.Status -ne "Valid" -or -not $RuntimeSignature.SignerCertificate -or
        $RuntimeSignature.SignerCertificate.Subject -notmatch "(?i)(^|, )O=Microsoft Corporation(,|$)") {
        throw "Refusing an unsigned or non-Microsoft VC++ runtime installer from the CKA package."
    }
    Invoke-CkaTool $Redistributable @("/install", "/quiet", "/norestart") 600 @(0, 1638, 3010)
}

Invoke-CkaTool (Join-Path $InstallRoot "RegisterKSP.exe") @()
Invoke-CkaTool (Join-Path $InstallRoot "eSignerCSP.Config.exe") @() 60
Invoke-CkaTool (Join-Path $InstallRoot "eSignerCKATool.exe") @(
    "config", "-mode", "product", "-user", $env:SSL_ESIGNER_USERNAME,
    "-pass", $env:SSL_ESIGNER_PASSWORD, "-totp", $env:SSL_ESIGNER_TOTP_SECRET,
    "-key", $MasterKey, "-r"
) 300
Invoke-CkaTool (Join-Path $InstallRoot "eSignerCKATool.exe") @("unload")
$LoadFailure = $null
try { Invoke-CkaTool (Join-Path $InstallRoot "eSignerCKATool.exe") @("load") 300 }
catch { $LoadFailure = $_.Exception }
$OwnedLoadedCertificates = @(
    Get-ChildItem Cert:\CurrentUser\My |
        Where-Object { -not $PreexistingMySet.Contains([string]$_.Thumbprint) }
)
$OwnedLoadedThumbprints = @($OwnedLoadedCertificates | ForEach-Object { [string]$_.Thumbprint } | Sort-Object -Unique)
# Record every newly loaded CurrentUser\My certificate even if validation or the
# load command failed, so the always() cleanup step can remove the exact run-owned
# certificate entries without touching anything that predated this job.
Write-CkaOwnership -OwnedSignerThumbprints $OwnedLoadedThumbprints
if ($LoadFailure) { throw $LoadFailure }
if ($OwnedLoadedCertificates.Count -ne 1) { throw "Expected CKA load to create exactly one new cloud-HSM certificate." }
$Certificate = $OwnedLoadedCertificates[0]
$CertificateSimpleName = $Certificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)
if (-not $Certificate.HasPrivateKey -or $AllowedNames -cnotcontains $CertificateSimpleName) {
    throw "The loaded cloud-HSM certificate is not an exact LAI ZEYU or 来泽宇 private-key signer."
}
Write-CkaOwnership -OwnedSignerThumbprints $OwnedLoadedThumbprints -SignerThumbprint $Certificate.Thumbprint
if ($Certificate.Subject -ceq $Certificate.Issuer) { throw "The trusted release certificate may not be self-issued." }
if ($Certificate.Issuer -notmatch "(?i)(^|, )(O=SSL Corp|CN=SSL\.com[^,]*)(,|$)") { throw "The loaded signer was not issued through the expected SSL.com trust hierarchy." }
if (-not (@($Certificate.EnhancedKeyUsageList) | Where-Object { $_.ObjectId.Value -ceq "1.3.6.1.5.5.7.3.3" })) { throw "The loaded SSL.com signer lacks the Code Signing EKU." }
if ([DateTime]::UtcNow -lt $Certificate.NotBefore.ToUniversalTime() -or [DateTime]::UtcNow -ge $Certificate.NotAfter.ToUniversalTime()) { throw "The loaded SSL.com signer is outside its validity interval." }
if ($Certificate.Thumbprint -cnotmatch "^[0-9A-F]{40}$") { throw "Loaded signer thumbprint is invalid." }
if (-not (Test-Path -LiteralPath $MasterKey)) { throw "Automated CKA master key was not created in RUNNER_TEMP." }
"thumbprint=$($Certificate.Thumbprint)" >> $env:GITHUB_OUTPUT
Write-Host "Loaded exactly one permitted SSL.com cloud-HSM signer through CKA/KSP."
