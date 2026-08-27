[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PortableRoot,
    [Parameter(Mandatory = $true)][string]$CertificateThumbprint
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true
Set-StrictMode -Version Latest
if (-not $IsWindows -or $env:AEGIS_TRUSTED_GITHUB_BUILD -cne "1") { throw "Trusted portable signing is restricted to the protected Windows release workflow." }
if ($CertificateThumbprint -cnotmatch "^[0-9A-F]{40}$") { throw "Cloud-HSM certificate thumbprint is invalid." }
. (Join-Path $PSScriptRoot "trusted-windows-sdk-tool.ps1")

function Test-PortableExecutable([string]$Path) {
    $Stream = [IO.File]::OpenRead($Path)
    try {
        if ($Stream.Length -lt 64 -or $Stream.ReadByte() -ne 0x4D -or $Stream.ReadByte() -ne 0x5A) { return $false }
        $Stream.Position = 0x3C
        $OffsetBytes = New-Object byte[] 4
        if ($Stream.Read($OffsetBytes, 0, 4) -ne 4) { return $false }
        $Offset = [BitConverter]::ToUInt32($OffsetBytes, 0)
        if ($Offset -gt $Stream.Length - 4) { return $false }
        $Stream.Position = $Offset
        $Signature = New-Object byte[] 4
        return $Stream.Read($Signature, 0, 4) -eq 4 -and $Signature[0] -eq 0x50 -and $Signature[1] -eq 0x45 -and $Signature[2] -eq 0 -and $Signature[3] -eq 0
    } finally { $Stream.Dispose() }
}

$RequestedRoot = Get-Item -LiteralPath $PortableRoot -Force -ErrorAction Stop
if (($RequestedRoot.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Portable signing root is a reparse point." }
$Root = (Resolve-Path $PortableRoot).Path
$Signtool = Get-AegisTrustedWindowsSdkTool -Name "signtool.exe"
$Entries = @(Get-ChildItem -LiteralPath $Root -Recurse -Force)
if (@($Entries | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 }).Count -ne 0) { throw "Portable signing root contains a reparse-point entry." }
$PeFiles = @($Entries | Where-Object { -not $_.PSIsContainer -and (Test-PortableExecutable $_.FullName) })
if ($PeFiles.Count -lt 2) { throw "Portable staging contains too few PE files." }

function Invoke-BoundedSignTool([string]$FilePath) {
    $Info = [Diagnostics.ProcessStartInfo]::new()
    $Info.FileName = $Signtool
    $Info.UseShellExecute = $false
    $Info.CreateNoWindow = $true
    $Info.RedirectStandardOutput = $true
    $Info.RedirectStandardError = $true
    foreach ($Argument in @("sign", "/fd", "SHA256", "/tr", "http://ts.ssl.com", "/td", "SHA256", "/sha1", $CertificateThumbprint, $FilePath)) {
        [void]$Info.ArgumentList.Add($Argument)
    }
    $Process = [Diagnostics.Process]::new()
    $Process.StartInfo = $Info
    $Started = $false
    try {
        if (-not $Process.Start()) { throw "Cloud-HSM SignTool did not start." }
        $Started = $true
        $Stdout = $Process.StandardOutput.ReadToEndAsync()
        $Stderr = $Process.StandardError.ReadToEndAsync()
        if (-not $Process.WaitForExit(300000)) {
            try { $Process.Kill($true) } catch { }
            if (-not $Process.WaitForExit(30000)) { throw "Cloud-HSM SignTool timed out and its process tree remained." }
            throw "Cloud-HSM SignTool exceeded its five-minute per-file hard timeout."
        }
        $OutputTasks = [Threading.Tasks.Task[]]@($Stdout, $Stderr)
        if (-not [Threading.Tasks.Task]::WaitAll($OutputTasks, 30000)) { throw "Cloud-HSM SignTool output pipes did not close within the hard drain timeout." }
        $Output = $Stdout.GetAwaiter().GetResult() + $Stderr.GetAwaiter().GetResult()
        if ($Output) { Write-Host $Output }
        if ($Process.ExitCode -ne 0) { throw "Cloud-HSM SignTool failed with exit code $($Process.ExitCode)." }
    } finally {
        $CleanupError = $null
        if ($Started) {
            try {
                if (-not $Process.HasExited) {
                    $Process.Kill($true)
                    if (-not $Process.WaitForExit(30000)) { throw "SignTool process tree remained during fail-safe cleanup." }
                }
            } catch { $CleanupError = $_.Exception }
        }
        $Process.Dispose()
        if ($CleanupError) { throw $CleanupError }
    }
}

foreach ($File in $PeFiles) {
    try { Invoke-BoundedSignTool -FilePath $File.FullName }
    catch { throw "Cloud-HSM SignTool failed for $($File.Name): $($_.Exception.Message)" }
}
Write-Host "Cloud-HSM signed all $($PeFiles.Count) PE files discovered by DOS+PE magic."
