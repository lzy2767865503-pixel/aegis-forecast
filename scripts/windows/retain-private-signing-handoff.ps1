[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PrivateRoot,
    [Parameter(Mandatory = $true)][string]$BuildAccountSid,
    [Parameter(Mandatory = $true)][string]$SignerAccountSid,
    [Parameter(Mandatory = $true)][string]$ExpectedBuildRunnerName,
    [Parameter(Mandatory = $true)][string]$ExpectedSignerRunnerName
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true
Set-StrictMode -Version Latest

if (-not $IsWindows -or $env:GITHUB_RUN_ID -cnotmatch '^\d+$' -or
    $env:GITHUB_RUN_ATTEMPT -cnotmatch '^\d+$' -or $env:RUNNER_NAME -cne $ExpectedBuildRunnerName) {
    throw "Private signing handoff requires the exact protected Windows build runner and GitHub run identity."
}
if ($BuildAccountSid -cnotmatch '^S-1-(?:\d+-){1,14}\d+$' -or
    $SignerAccountSid -cnotmatch '^S-1-(?:\d+-){1,14}\d+$' -or
    $BuildAccountSid -ceq $SignerAccountSid -or
    [string]::IsNullOrWhiteSpace($ExpectedSignerRunnerName) -or
    $ExpectedBuildRunnerName -ceq $ExpectedSignerRunnerName) {
    throw "Build and signer runners/accounts must be separate exact protected identities."
}

function Test-PathInside {
    param([string]$Child, [string]$Parent)
    $ExactChild = [IO.Path]::GetFullPath($Child).TrimEnd('\')
    $ExactParent = [IO.Path]::GetFullPath($Parent).TrimEnd('\')
    return $ExactChild.Equals($ExactParent, [StringComparison]::OrdinalIgnoreCase) -or
        $ExactChild.StartsWith($ExactParent + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Assert-NoReparseAncestor {
    param([string]$Path, [string]$VolumeRoot)
    $Current = Get-Item -LiteralPath $Path -Force
    while ($Current) {
        if (($Current.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Private signing handoff has a reparse-point ancestor."
        }
        if ($Current.FullName.TrimEnd('\').Equals($VolumeRoot.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) { return }
        $Current = $Current.Parent
    }
    throw "Private signing handoff did not reach its fixed-volume root."
}

function Assert-ExactAcl {
    param([string]$Path, [string[]]$AllowedSids, [string]$Label, [switch]$RequireProtected)
    $Acl = Get-Acl -LiteralPath $Path
    if ($RequireProtected -and -not $Acl.AreAccessRulesProtected) { throw "$Label ACL is not protected." }
    $Rules = @($Acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
    $Expected = @($AllowedSids | Sort-Object -Unique)
    $Actual = @($Rules | ForEach-Object { [string]$_.IdentityReference.Value } | Sort-Object -Unique)
    if (($Actual -join '|') -cne ($Expected -join '|') -or
        @($Rules | Where-Object { $_.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow }).Count -ne 0) {
        throw "$Label ACL is outside the exact build/signer/SYSTEM/Administrators allowlist."
    }
    foreach ($Sid in $Expected) {
        $ExactRules = @($Rules | Where-Object {
            [string]$_.IdentityReference.Value -ceq $Sid -and
            (($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -eq [Security.AccessControl.FileSystemRights]::FullControl)
        })
        if ($ExactRules.Count -lt 1) { throw "$Label lacks FullControl for one exact approved SID." }
    }
    if ([string]$Acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cnotin $Expected) {
        throw "$Label owner is outside the exact approved SID set."
    }
    return $Acl
}

function Get-TreeEvidence {
    param([string]$Root)
    $ExactRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $Entries = @(Get-ChildItem -LiteralPath $ExactRoot -Recurse -Force)
    if (@($Entries | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 }).Count -ne 0) {
        throw "Unsigned portable input contains a reparse point."
    }
    $Files = @($Entries | Where-Object { -not $_.PSIsContainer } | Sort-Object FullName)
    if ($Files.Count -lt 2) { throw "Unsigned portable input contains too few files." }
    $Rows = [Collections.Generic.List[object]]::new()
    foreach ($File in $Files) {
        $Relative = [IO.Path]::GetRelativePath($ExactRoot, $File.FullName).Replace('\', '/')
        if ([string]::IsNullOrWhiteSpace($Relative) -or $Relative.StartsWith('../', [StringComparison]::Ordinal) -or
            [IO.Path]::IsPathRooted($Relative)) { throw "Unsigned portable inventory escaped its exact root." }
        $Rows.Add([ordered]@{
            path = $Relative
            size = [long]$File.Length
            sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $File.FullName).Hash.ToLowerInvariant()
        })
    }
    $Canonical = (@($Rows | ForEach-Object { "$($_.sha256) $($_.size) $($_.path)" }) -join "`n") + "`n"
    $Hasher = [Security.Cryptography.SHA256]::Create()
    try {
        $TreeHash = [Convert]::ToHexString($Hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($Canonical))).ToLowerInvariant()
    } finally { $Hasher.Dispose() }
    return [pscustomobject]@{ files = @($Rows); sha256 = $TreeHash }
}

$Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
try { $CurrentSid = [string]$Identity.User.Value } finally { $Identity.Dispose() }
if ($CurrentSid -cne $BuildAccountSid) { throw "Current Windows account is not the protected build account SID." }

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$SourceRoot = (Resolve-Path (Join-Path $ProjectRoot 'artifacts\github-release\portable')).Path
$ExactPrivateRoot = [IO.Path]::GetFullPath($PrivateRoot).TrimEnd('\')
if (-not [IO.Path]::IsPathFullyQualified($ExactPrivateRoot) -or $ExactPrivateRoot.StartsWith('\\') -or
    [IO.Path]::GetFileName($ExactPrivateRoot) -cne 'AegisGitHubSigningHandoff' -or
    -not (Test-Path -LiteralPath $ExactPrivateRoot -PathType Container)) {
    throw "AEGIS_PRIVATE_SIGNING_HANDOFF_ROOT must be a pre-provisioned absolute local AegisGitHubSigningHandoff directory."
}
$VolumeRoot = [IO.Path]::GetPathRoot($ExactPrivateRoot)
$Drive = [IO.DriveInfo]::new($VolumeRoot)
if (-not $Drive.IsReady -or $Drive.DriveType -ne [IO.DriveType]::Fixed -or $Drive.DriveFormat -cne 'NTFS' -or
    $ExactPrivateRoot.TrimEnd('\').Equals($VolumeRoot.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
    throw "AEGIS_PRIVATE_SIGNING_HANDOFF_ROOT must be below a ready local fixed NTFS volume root."
}
foreach ($Forbidden in @($ProjectRoot, $env:GITHUB_WORKSPACE, $env:RUNNER_TEMP, $env:OneDrive, $env:OneDriveConsumer, $env:OneDriveCommercial)) {
    if ($Forbidden -and ((Test-PathInside $ExactPrivateRoot $Forbidden) -or (Test-PathInside $Forbidden $ExactPrivateRoot))) {
        throw "Private signing handoff overlaps a workspace, temporary directory or cloud-sync root."
    }
}
Assert-NoReparseAncestor -Path $ExactPrivateRoot -VolumeRoot $VolumeRoot
$AllowedSids = @($BuildAccountSid, $SignerAccountSid, 'S-1-5-18', 'S-1-5-32-544') | Sort-Object -Unique
[void](Assert-ExactAcl -Path $ExactPrivateRoot -AllowedSids $AllowedSids -Label 'Private signing root' -RequireProtected)

$SourceCommit = (& git -C $ProjectRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $SourceCommit -cnotmatch '^[0-9a-f]{40}$' -or
    $env:RELEASE_TAG -cne 'windows-v1.5.0' -or $env:ARCHIVE_NAME -cne 'QuantScenarioStudio-by-LAI-ZEYU-1.5.0-x64.zip') {
    throw "Unsigned signing handoff source/tag/archive identity is invalid."
}
$SourceEvidence = Get-TreeEvidence -Root $SourceRoot
$MachineGuid = [string](Get-ItemPropertyValue -LiteralPath 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid)
if ($MachineGuid -cnotmatch '^[{]?[0-9A-Fa-f-]{36,38}[}]?$') { throw "Protected build host MachineGuid is malformed." }
$MachineHasher = [Security.Cryptography.SHA256]::Create()
try {
    $MachineGuidSha256 = [Convert]::ToHexString(
        $MachineHasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($MachineGuid.ToLowerInvariant()))
    ).ToLowerInvariant()
} finally { $MachineHasher.Dispose() }
$RunLeaf = "aegis-github-1.5.0-$env:GITHUB_RUN_ID-$env:GITHUB_RUN_ATTEMPT-$($SourceCommit.Substring(0, 12))"
$FinalRoot = Join-Path $ExactPrivateRoot $RunLeaf
$IncompleteRoot = "$FinalRoot.incomplete"
if ((Test-Path -LiteralPath $FinalRoot) -or (Test-Path -LiteralPath $IncompleteRoot)) {
    throw "The exact private signing handoff run already exists."
}

$CreatedIncomplete = $false
$Completed = $false
try {
    New-Item -ItemType Directory -Path $IncompleteRoot | Out-Null
    $CreatedIncomplete = $true
    $Security = [Security.AccessControl.DirectorySecurity]::new()
    $Security.SetOwner([Security.Principal.SecurityIdentifier]::new($BuildAccountSid))
    $Security.SetAccessRuleProtection($true, $false)
    foreach ($Sid in $AllowedSids) {
        $Rule = [Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.SecurityIdentifier]::new($Sid),
            [Security.AccessControl.FileSystemRights]::FullControl,
            [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit',
            [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Allow
        )
        [void]$Security.AddAccessRule($Rule)
    }
    Set-Acl -LiteralPath $IncompleteRoot -AclObject $Security
    [void](Assert-ExactAcl -Path $IncompleteRoot -AllowedSids $AllowedSids -Label 'Incomplete signing handoff' -RequireProtected)

    $CopiedRoot = Join-Path $IncompleteRoot 'portable-unsigned'
    Copy-Item -LiteralPath $SourceRoot -Destination $CopiedRoot -Recurse
    $CopiedEvidence = Get-TreeEvidence -Root $CopiedRoot
    if ($CopiedEvidence.sha256 -cne $SourceEvidence.sha256 -or
        (@($CopiedEvidence.files | ConvertTo-Json -Depth 4 -Compress) -join '') -cne (@($SourceEvidence.files | ConvertTo-Json -Depth 4 -Compress) -join '')) {
        throw "ACL-protected unsigned portable copy differs from the built bytes."
    }
    foreach ($Entry in @(Get-ChildItem -LiteralPath $IncompleteRoot -Recurse -Force)) {
        [void](Assert-ExactAcl -Path $Entry.FullName -AllowedSids $AllowedSids -Label $Entry.Name)
    }

    $Manifest = [ordered]@{
        schemaVersion = 1
        product = 'Quant Scenario Studio by LAI ZEYU'
        author = 'LAI ZEYU（来泽宇）'
        githubRunId = $env:GITHUB_RUN_ID
        githubRunAttempt = $env:GITHUB_RUN_ATTEMPT
        sourceCommit = $SourceCommit
        releaseTag = $env:RELEASE_TAG
        archiveName = $env:ARCHIVE_NAME
        buildRunnerName = $ExpectedBuildRunnerName
        signerRunnerName = $ExpectedSignerRunnerName
        buildAccountSid = $BuildAccountSid
        signerAccountSid = $SignerAccountSid
        machineGuidSha256 = $MachineGuidSha256
        inputTreeSha256 = $SourceEvidence.sha256
        inputFiles = @($SourceEvidence.files)
        unsignedInput = $true
        githubArtifactUploaded = $false
        storageBoundary = 'LOCAL_FIXED_NTFS_EXACT_ACL'
    }
    $ManifestPath = Join-Path $IncompleteRoot 'unsigned-signing-handoff.json'
    [IO.File]::WriteAllText($ManifestPath, (($Manifest | ConvertTo-Json -Depth 6 -Compress) + "`n"), [Text.UTF8Encoding]::new($false))
    [void](Assert-ExactAcl -Path $ManifestPath -AllowedSids $AllowedSids -Label 'unsigned-signing-handoff.json')
    [IO.Directory]::Move($IncompleteRoot, $FinalRoot)
    $Completed = $true
    "handoff_leaf=$RunLeaf" >> $env:GITHUB_OUTPUT
    "source_commit=$SourceCommit" >> $env:GITHUB_OUTPUT
    "input_tree_sha256=$($SourceEvidence.sha256)" >> $env:GITHUB_OUTPUT
    Write-Host "Retained unsigned release input only in the exact local NTFS build-to-signer handoff; no unsigned artifact was uploaded."
} catch {
    $Failure = $_
    if (-not $Completed -and $CreatedIncomplete -and (Test-Path -LiteralPath $IncompleteRoot)) {
        $Item = Get-Item -LiteralPath $IncompleteRoot -Force
        if ($Item.Parent.FullName.TrimEnd('\').Equals($ExactPrivateRoot, [StringComparison]::OrdinalIgnoreCase) -and
            $Item.Name -ceq "$RunLeaf.incomplete" -and (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0)) {
            Remove-Item -LiteralPath $IncompleteRoot -Recurse -Force
        }
    }
    throw $Failure
}
