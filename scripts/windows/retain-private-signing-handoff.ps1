[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PrivateRoot,
    [Parameter(Mandatory = $true)][string]$BuildAccountSid,
    [Parameter(Mandatory = $true)][string]$SignerAccountSid,
    [Parameter(Mandatory = $true)][string]$ExpectedBuildRunnerName,
    [Parameter(Mandatory = $true)][string]$ExpectedSignerRunnerName
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
Set-StrictMode -Version Latest

if (-not $IsWindows -or $env:GITHUB_RUN_ID -cnotmatch '^\d+$' -or
    $env:GITHUB_RUN_ATTEMPT -cnotmatch '^\d+$' -or $env:RUNNER_NAME -cne $ExpectedBuildRunnerName) {
    throw 'Private signing ingress requires the exact protected Windows build runner and GitHub run identity.'
}
if ($BuildAccountSid -cnotmatch '^S-1-(?:\d+-){1,14}\d+$' -or
    $SignerAccountSid -cnotmatch '^S-1-(?:\d+-){1,14}\d+$' -or
    $BuildAccountSid -ceq $SignerAccountSid -or [string]::IsNullOrWhiteSpace($ExpectedSignerRunnerName) -or
    $ExpectedBuildRunnerName -ceq $ExpectedSignerRunnerName) {
    throw 'Build and signer runners/accounts must be separate exact protected identities.'
}

function Test-PathInside([string]$Child, [string]$Parent) {
    $ExactChild = [IO.Path]::GetFullPath($Child).TrimEnd('\')
    $ExactParent = [IO.Path]::GetFullPath($Parent).TrimEnd('\')
    return $ExactChild.Equals($ExactParent, [StringComparison]::OrdinalIgnoreCase) -or
        $ExactChild.StartsWith($ExactParent + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Get-AclRules([string]$Path) {
    $Acl = Get-Acl -LiteralPath $Path
    return [pscustomobject]@{
        acl = $Acl
        rules = @($Acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
        owner = [string]$Acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
    }
}

function Assert-NoWritableBroadAncestor([string]$Path, [string]$VolumeRoot) {
    $BroadSids = @('S-1-1-0', 'S-1-5-11', 'S-1-5-32-545', 'S-1-5-32-546')
    $Dangerous = [Security.AccessControl.FileSystemRights]::Write -bor
        [Security.AccessControl.FileSystemRights]::Modify -bor
        [Security.AccessControl.FileSystemRights]::Delete -bor
        [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
        [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [Security.AccessControl.FileSystemRights]::TakeOwnership
    $Current = Get-Item -LiteralPath $Path -Force
    while ($Current) {
        if (($Current.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Private signing boundary has a reparse-point ancestor.'
        }
        $Evidence = Get-AclRules -Path $Current.FullName
        if (@($Evidence.rules | Where-Object {
            $_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
            (([string]$_.IdentityReference.Value -cin $BroadSids) -or [string]$_.IdentityReference.Value -ceq $BuildAccountSid) -and
            (($_.FileSystemRights -band $Dangerous) -ne 0)
        }).Count -ne 0) {
            throw 'A private signing ancestor grants write/delete/ACL authority to the build SID or a broad principal.'
        }
        if ($Current.FullName.TrimEnd('\').Equals($VolumeRoot.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) { return }
        $Current = $Current.Parent
    }
    throw 'Private signing boundary did not reach its fixed-volume root.'
}

function Assert-ExactFullControlAcl {
    param([string]$Path, [string[]]$AllowedSids, [string[]]$AllowedOwners, [string]$Label)
    $Evidence = Get-AclRules -Path $Path
    if (-not $Evidence.acl.AreAccessRulesProtected) { throw "$Label ACL is not protected." }
    $Expected = @($AllowedSids | Sort-Object -Unique)
    $Actual = @($Evidence.rules | ForEach-Object { [string]$_.IdentityReference.Value } | Sort-Object -Unique)
    if (($Actual -join '|') -cne ($Expected -join '|') -or $Evidence.owner -cnotin $AllowedOwners -or
        @($Evidence.rules | Where-Object { $_.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow }).Count -ne 0) {
        throw "$Label ACL identities, owner, or allow-only policy is not exact."
    }
    foreach ($Sid in $Expected) {
        if (@($Evidence.rules | Where-Object {
            [string]$_.IdentityReference.Value -ceq $Sid -and
            (($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -eq [Security.AccessControl.FileSystemRights]::FullControl)
        }).Count -lt 1) { throw "$Label lacks FullControl for an exact approved SID." }
    }
    return $Evidence.acl
}

function Assert-PrivateRootAcl([string]$Path) {
    $Evidence = Get-AclRules -Path $Path
    $ExpectedSids = @($BuildAccountSid, $SignerAccountSid, 'S-1-5-18') | Sort-Object
    $ActualSids = @($Evidence.rules | ForEach-Object { [string]$_.IdentityReference.Value } | Sort-Object -Unique)
    $Dangerous = [Security.AccessControl.FileSystemRights]::Write -bor
        [Security.AccessControl.FileSystemRights]::Modify -bor
        [Security.AccessControl.FileSystemRights]::Delete -bor
        [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
        [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [Security.AccessControl.FileSystemRights]::TakeOwnership
    if (-not $Evidence.acl.AreAccessRulesProtected -or ($ActualSids -join '|') -cne ($ExpectedSids -join '|') -or
        $Evidence.owner -cnotin @($SignerAccountSid, 'S-1-5-18') -or
        @($Evidence.rules | Where-Object { $_.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow }).Count -ne 0) {
        throw 'Private signing root ACL must be protected, signer/SYSTEM-owned, and limited to build/signer/SYSTEM.'
    }
    $BuildRules = @($Evidence.rules | Where-Object { [string]$_.IdentityReference.Value -ceq $BuildAccountSid })
    if ($BuildRules.Count -ne 1 -or ($BuildRules[0].FileSystemRights -band $Dangerous) -ne 0 -or
        ($BuildRules[0].FileSystemRights -band [Security.AccessControl.FileSystemRights]::ReadAndExecute) -ne [Security.AccessControl.FileSystemRights]::ReadAndExecute -or
        $BuildRules[0].InheritanceFlags -ne [Security.AccessControl.InheritanceFlags]::None) {
        throw 'Build SID may only traverse/read the private root and may not inherit into signer-only vault.'
    }
    foreach ($Sid in @($SignerAccountSid, 'S-1-5-18')) {
        if (@($Evidence.rules | Where-Object {
            [string]$_.IdentityReference.Value -ceq $Sid -and
            (($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -eq [Security.AccessControl.FileSystemRights]::FullControl)
        }).Count -lt 1) { throw 'Private signing root lacks signer/SYSTEM FullControl.' }
    }
}

function Set-ExactFullControlAcl([string]$Path, [string[]]$AllowedSids, [string]$OwnerSid) {
    $Security = [Security.AccessControl.DirectorySecurity]::new()
    $Security.SetOwner([Security.Principal.SecurityIdentifier]::new($OwnerSid))
    $Security.SetAccessRuleProtection($true, $false)
    foreach ($Sid in @($AllowedSids | Sort-Object -Unique)) {
        $Rule = [Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.SecurityIdentifier]::new($Sid),
            [Security.AccessControl.FileSystemRights]::FullControl,
            [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit',
            [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Allow
        )
        [void]$Security.AddAccessRule($Rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $Security
}

function Get-TreeEvidence([string]$Root) {
    $ExactRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $RootItem = Get-Item -LiteralPath $ExactRoot -Force
    $Entries = @(Get-ChildItem -LiteralPath $ExactRoot -Recurse -Force)
    if (($RootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        @($Entries | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 }).Count -ne 0) {
        throw 'Unsigned portable input contains a junction or reparse point.'
    }
    if (@($Entries | Where-Object { $_.PSIsContainer -and @(Get-ChildItem -LiteralPath $_.FullName -File -Recurse -Force).Count -eq 0 }).Count -ne 0) {
        throw 'Unsigned portable input contains an unbound empty directory.'
    }
    $Files = @($Entries | Where-Object { -not $_.PSIsContainer } | Sort-Object FullName)
    if ($Files.Count -lt 2 -or $Files.Count -gt 20000) { throw 'Unsigned portable input file count is outside the strict bound.' }
    $Rows = [Collections.Generic.List[object]]::new()
    [long]$Total = 0
    foreach ($File in $Files) {
        $Relative = [IO.Path]::GetRelativePath($ExactRoot, $File.FullName).Replace('\', '/')
        $Total += [long]$File.Length
        if ([string]::IsNullOrWhiteSpace($Relative) -or $Relative.StartsWith('../', [StringComparison]::Ordinal) -or
            [IO.Path]::IsPathRooted($Relative) -or $File.Length -gt 512MB -or $Total -gt 2GB) {
            throw 'Unsigned portable inventory path or size escaped its strict boundary.'
        }
        $Rows.Add([ordered]@{ path = $Relative; size = [long]$File.Length; sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $File.FullName).Hash.ToLowerInvariant() })
    }
    $Canonical = (@($Rows | ForEach-Object { "$($_.sha256) $($_.size) $($_.path)" }) -join "`n") + "`n"
    $Hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Canonical))).ToLowerInvariant()
    return [pscustomobject]@{ files = @($Rows); sha256 = $Hash }
}

$Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
try {
    $CurrentSid = [string]$Identity.User.Value
    $Principal = [Security.Principal.WindowsPrincipal]::new($Identity)
    $BuildIsAdministrator = $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} finally { $Identity.Dispose() }
if ($CurrentSid -cne $BuildAccountSid -or $BuildIsAdministrator) {
    throw 'The protected build account SID must match and must not be a local Administrator.'
}

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$SourceRoot = (Resolve-Path (Join-Path $ProjectRoot 'artifacts\github-release\portable')).Path
$ExactPrivateRoot = [IO.Path]::GetFullPath($PrivateRoot).TrimEnd('\')
if (-not [IO.Path]::IsPathFullyQualified($ExactPrivateRoot) -or $ExactPrivateRoot.StartsWith('\\') -or
    [IO.Path]::GetFileName($ExactPrivateRoot) -cne 'AegisGitHubSigningHandoff' -or
    -not (Test-Path -LiteralPath $ExactPrivateRoot -PathType Container)) {
    throw 'AEGIS_PRIVATE_SIGNING_HANDOFF_ROOT must be the pre-provisioned absolute local AegisGitHubSigningHandoff directory.'
}
$VolumeRoot = [IO.Path]::GetPathRoot($ExactPrivateRoot)
$Drive = [IO.DriveInfo]::new($VolumeRoot)
if (-not $Drive.IsReady -or $Drive.DriveType -ne [IO.DriveType]::Fixed -or $Drive.DriveFormat -cne 'NTFS' -or
    $ExactPrivateRoot.TrimEnd('\').Equals($VolumeRoot.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Private signing handoff must be below a ready local fixed NTFS volume root.'
}
foreach ($Forbidden in @($ProjectRoot, $env:GITHUB_WORKSPACE, $env:RUNNER_TEMP, $env:OneDrive, $env:OneDriveConsumer, $env:OneDriveCommercial)) {
    if ($Forbidden -and ((Test-PathInside $ExactPrivateRoot $Forbidden) -or (Test-PathInside $Forbidden $ExactPrivateRoot))) {
        throw 'Private signing handoff overlaps a workspace, temporary directory, or cloud-sync root.'
    }
}
Assert-NoWritableBroadAncestor -Path $ExactPrivateRoot -VolumeRoot $VolumeRoot
Assert-PrivateRootAcl -Path $ExactPrivateRoot
$IngressRoot = Join-Path $ExactPrivateRoot 'ingress'
$VaultRoot = Join-Path $ExactPrivateRoot 'signer-vault'
if (-not (Test-Path -LiteralPath $IngressRoot -PathType Container) -or -not (Test-Path -LiteralPath $VaultRoot -PathType Container)) {
    throw 'Pre-provisioned ingress and signer-vault directories are both required.'
}
foreach ($BoundaryRoot in @($IngressRoot, $VaultRoot)) {
    $BoundaryItem = Get-Item -LiteralPath $BoundaryRoot -Force
    if (($BoundaryItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        -not $BoundaryItem.Parent.FullName.TrimEnd('\').Equals($ExactPrivateRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Ingress and signer-vault must be direct non-reparse children of the exact private root.'
    }
}
$IngressSids = @($BuildAccountSid, $SignerAccountSid, 'S-1-5-18')
$VaultSids = @($SignerAccountSid, 'S-1-5-18')
[void](Assert-ExactFullControlAcl -Path $IngressRoot -AllowedSids $IngressSids -AllowedOwners @($BuildAccountSid, $SignerAccountSid, 'S-1-5-18') -Label 'Signing ingress root')
[void](Assert-ExactFullControlAcl -Path $VaultRoot -AllowedSids $VaultSids -AllowedOwners $VaultSids -Label 'Signer-only vault root')

$SourceCommit = (& git -C $ProjectRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $SourceCommit -cnotmatch '^[0-9a-f]{40}$' -or
    $env:RELEASE_TAG -cne 'windows-v1.5.0' -or $env:ARCHIVE_NAME -cne 'QuantScenarioStudio-by-LAI-ZEYU-1.5.0-x64.zip') {
    throw 'Unsigned signing ingress source/tag/archive identity is invalid.'
}
$SourceEvidenceBefore = Get-TreeEvidence -Root $SourceRoot
$MachineGuid = [string](Get-ItemPropertyValue -LiteralPath 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid)
if ($MachineGuid -cnotmatch '^[{]?[0-9A-Fa-f-]{36,38}[}]?$') { throw 'Protected build host MachineGuid is malformed.' }
$MachineGuidSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($MachineGuid.ToLowerInvariant()))).ToLowerInvariant()
$RunLeaf = "aegis-github-1.5.0-$env:GITHUB_RUN_ID-$env:GITHUB_RUN_ATTEMPT-$($SourceCommit.Substring(0, 12))"
$FinalRoot = Join-Path $IngressRoot $RunLeaf
$IncompleteRoot = "$FinalRoot.incomplete"
if ((Test-Path -LiteralPath $FinalRoot) -or (Test-Path -LiteralPath $IncompleteRoot) -or
    (Test-Path -LiteralPath (Join-Path $VaultRoot $RunLeaf)) -or (Test-Path -LiteralPath (Join-Path $VaultRoot "$RunLeaf.claiming"))) {
    throw 'The exact ingress/vault signing run identity already exists.'
}

$CreatedIncomplete = $false
$Completed = $false
try {
    New-Item -ItemType Directory -Path $IncompleteRoot | Out-Null
    $CreatedIncomplete = $true
    Set-ExactFullControlAcl -Path $IncompleteRoot -AllowedSids $IngressSids -OwnerSid $BuildAccountSid
    [void](Assert-ExactFullControlAcl -Path $IncompleteRoot -AllowedSids $IngressSids -AllowedOwners @($BuildAccountSid) -Label 'Incomplete signing ingress')
    $CopiedRoot = Join-Path $IncompleteRoot 'portable-unsigned'
    Copy-Item -LiteralPath $SourceRoot -Destination $CopiedRoot -Recurse
    $CopiedEvidence = Get-TreeEvidence -Root $CopiedRoot
    $SourceEvidenceAfter = Get-TreeEvidence -Root $SourceRoot
    if ($SourceEvidenceBefore.sha256 -cne $SourceEvidenceAfter.sha256 -or
        $CopiedEvidence.sha256 -cne $SourceEvidenceBefore.sha256 -or
        ($CopiedEvidence.files | ConvertTo-Json -Depth 4 -Compress) -cne ($SourceEvidenceBefore.files | ConvertTo-Json -Depth 4 -Compress)) {
        throw 'Concurrent build-tree replacement or ingress-copy drift was detected.'
    }
    foreach ($Entry in @((Get-Item -LiteralPath $CopiedRoot -Force); Get-ChildItem -LiteralPath $CopiedRoot -Recurse -Force)) {
        [void](Assert-ExactFullControlAcl -Path $Entry.FullName -AllowedSids $IngressSids -AllowedOwners $IngressSids -Label $Entry.Name)
    }
    $Manifest = [ordered]@{
        schemaVersion = 2
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
        buildAccountIsAdministrator = $false
        administratorsAclAllowed = $false
        machineGuidSha256 = $MachineGuidSha256
        inputTreeSha256 = $SourceEvidenceBefore.sha256
        inputFiles = @($SourceEvidenceBefore.files)
        ingressSubdirectory = 'ingress'
        vaultSubdirectory = 'signer-vault'
        handoffPhase = 'INGRESS_READY_FOR_EXCLUSIVE_SIGNER_CLAIM'
        unsignedInput = $true
        githubArtifactUploaded = $false
        storageBoundary = 'LOCAL_FIXED_NTFS_SPLIT_EXCLUSIVE_ACL'
    }
    $ManifestPath = Join-Path $IncompleteRoot 'unsigned-signing-handoff.json'
    [IO.File]::WriteAllText($ManifestPath, (($Manifest | ConvertTo-Json -Depth 6 -Compress) + "`n"), [Text.UTF8Encoding]::new($false))
    [void](Assert-ExactFullControlAcl -Path $ManifestPath -AllowedSids $IngressSids -AllowedOwners $IngressSids -Label 'unsigned-signing-handoff.json')
    [IO.Directory]::Move($IncompleteRoot, $FinalRoot)
    $Completed = $true
    $FinalEvidence = Get-TreeEvidence -Root (Join-Path $FinalRoot 'portable-unsigned')
    if ($FinalEvidence.sha256 -cne $SourceEvidenceBefore.sha256) { throw 'Final atomic ingress rename changed the unsigned input.' }
    "handoff_leaf=$RunLeaf" >> $env:GITHUB_OUTPUT
    "source_commit=$SourceCommit" >> $env:GITHUB_OUTPUT
    "input_tree_sha256=$($SourceEvidenceBefore.sha256)" >> $env:GITHUB_OUTPUT
    Write-Host 'Retained unsigned input in build-writable ingress only; signer-only vault and public artifacts remain untouched.'
} catch {
    $Failure = $_
    if (-not $Completed -and $CreatedIncomplete -and (Test-Path -LiteralPath $IncompleteRoot)) {
        $Item = Get-Item -LiteralPath $IncompleteRoot -Force
        if ($Item.Parent.FullName.TrimEnd('\').Equals($IngressRoot, [StringComparison]::OrdinalIgnoreCase) -and
            $Item.Name -ceq "$RunLeaf.incomplete" -and (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0)) {
            Remove-Item -LiteralPath $IncompleteRoot -Recurse -Force
        }
    }
    throw $Failure
}
