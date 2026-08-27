[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PrivateRoot,
    [switch]$ValidateOnly
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
if (-not $IsWindows) { throw "Private Store handoff retention requires Windows." }
if ($env:GITHUB_RUN_ID -cnotmatch '^[0-9]+$' -or $env:GITHUB_RUN_ATTEMPT -cnotmatch '^[0-9]+$') {
    throw "Private Store handoff retention requires an exact GitHub run identity."
}

function Test-PathInside {
    param([Parameter(Mandatory = $true)][string]$Child, [Parameter(Mandatory = $true)][string]$Parent)
    $ExactChild = [IO.Path]::GetFullPath($Child).TrimEnd("\")
    $ExactParent = [IO.Path]::GetFullPath($Parent).TrimEnd("\")
    return $ExactChild.Equals($ExactParent, [StringComparison]::OrdinalIgnoreCase) -or
        $ExactChild.StartsWith($ExactParent + "\", [StringComparison]::OrdinalIgnoreCase)
}

function Get-AclIdentitySids {
    param([Parameter(Mandatory = $true)][System.Security.AccessControl.FileSystemSecurity]$Acl)
    return @(
        $Acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) |
            ForEach-Object { [string]$_.IdentityReference.Value } |
            Sort-Object -Unique
    )
}

function Assert-ExactPrivateAcl {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$AllowedSids,
        [Parameter(Mandatory = $true)][string]$Label,
        [switch]$RequireProtected
    )
    $Acl = Get-Acl -LiteralPath $Path
    if ($RequireProtected -and -not $Acl.AreAccessRulesProtected) { throw "$Label ACL inherits from a parent." }
    $Rules = @($Acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
    $ActualSids = @(Get-AclIdentitySids $Acl)
    if (($ActualSids -join '|') -cne (@($AllowedSids | Sort-Object -Unique) -join '|')) {
        throw "$Label ACL includes an identity outside the exact runner/SYSTEM/Administrators allowlist."
    }
    foreach ($Sid in $AllowedSids) {
        $AllowRules = @($Rules | Where-Object {
            [string]$_.IdentityReference.Value -ceq $Sid -and
            $_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
            (($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -eq [Security.AccessControl.FileSystemRights]::FullControl)
        })
        if ($AllowRules.Count -eq 0) { throw "$Label lacks exact FullControl for an approved identity." }
    }
    if (@($Rules | Where-Object { $_.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow }).Count -ne 0) {
        throw "$Label contains a non-allow ACL entry."
    }
    $OwnerSid = $Acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
    if ($OwnerSid -cnotin $AllowedSids) { throw "$Label owner is outside the approved identity allowlist." }
    return $Acl
}

function Get-TextSha256([string]$Text) {
    return [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Text))
    ).ToLowerInvariant()
}

function Assert-ExactJsonSchema {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string[]]$ExpectedKeys,
        [Parameter(Mandatory = $true)][string]$Label
    )
    $ActualKeys = @($Value.PSObject.Properties.Name | Sort-Object)
    $SortedExpected = @($ExpectedKeys | Sort-Object)
    if (($ActualKeys -join '|') -cne ($SortedExpected -join '|')) { throw "$Label schema is not exact." }
}

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$ExactPrivateRoot = [IO.Path]::GetFullPath($PrivateRoot).TrimEnd("\")
if (-not [IO.Path]::IsPathFullyQualified($ExactPrivateRoot) -or $ExactPrivateRoot.StartsWith("\\")) {
    throw "AEGIS_PRIVATE_STORE_HANDOFF_ROOT must be an absolute local path."
}
if ([IO.Path]::GetFileName($ExactPrivateRoot) -cne "AegisStoreHandoff") {
    throw "AEGIS_PRIVATE_STORE_HANDOFF_ROOT must end in the exact dedicated directory name AegisStoreHandoff."
}
if (-not (Test-Path -LiteralPath $ExactPrivateRoot -PathType Container)) {
    throw "AEGIS_PRIVATE_STORE_HANDOFF_ROOT must be pre-provisioned before the workflow runs."
}
$VolumeRoot = [IO.Path]::GetPathRoot($ExactPrivateRoot)
if ($ExactPrivateRoot.TrimEnd("\").Equals($VolumeRoot.TrimEnd("\"), [StringComparison]::OrdinalIgnoreCase)) {
    throw "The private handoff root may not be a volume root."
}
$Drive = [IO.DriveInfo]::new($VolumeRoot)
if (-not $Drive.IsReady -or $Drive.DriveType -ne [IO.DriveType]::Fixed -or $Drive.DriveFormat -cne "NTFS") {
    throw "AEGIS_PRIVATE_STORE_HANDOFF_ROOT must be on a ready local fixed NTFS volume."
}
foreach ($ForbiddenRoot in @($ProjectRoot, $env:GITHUB_WORKSPACE, $env:RUNNER_TEMP, $env:OneDrive, $env:OneDriveConsumer, $env:OneDriveCommercial)) {
    if ($ForbiddenRoot -and ((Test-PathInside -Child $ExactPrivateRoot -Parent $ForbiddenRoot) -or
        (Test-PathInside -Child $ForbiddenRoot -Parent $ExactPrivateRoot))) {
        throw "AEGIS_PRIVATE_STORE_HANDOFF_ROOT overlaps a workspace, temporary, or OneDrive root."
    }
}
$Current = Get-Item -LiteralPath $ExactPrivateRoot -Force
while ($Current) {
    if (($Current.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Private handoff ancestor is a reparse point." }
    if ($Current.FullName.TrimEnd("\").Equals($VolumeRoot.TrimEnd("\"), [StringComparison]::OrdinalIgnoreCase)) { break }
    $Current = $Current.Parent
}

$Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
try { $CurrentSid = [string]$Identity.User.Value } finally { $Identity.Dispose() }
$AllowedSids = @($CurrentSid, 'S-1-5-18', 'S-1-5-32-544') | Sort-Object -Unique
$RootAcl = Assert-ExactPrivateAcl -Path $ExactPrivateRoot -AllowedSids $AllowedSids -Label "Private handoff root" -RequireProtected
if ($ValidateOnly) {
    Write-Host "Validated the pre-provisioned local fixed-NTFS exact-ACL Store handoff root without disclosing its path."
    return
}
$StagingRoot = (Resolve-Path (Join-Path $ProjectRoot "artifacts\store-handoff")).Path
$Source = Get-Content -Raw -LiteralPath (Join-Path $StagingRoot "store-submission-lineage.json") | ConvertFrom-Json
Assert-ExactJsonSchema $Source @(
    "schemaVersion", "product", "author", "publisherDisplayName", "partnerCenterProductId",
    "packageIdentity", "technicalPublisher", "sourceCommit", "submissionPackageFile",
    "submissionPackageSize", "submissionPackageSha256", "qaCandidatePackageSha256",
    "payloadFileCount", "payloadTreeSha256", "nativeQaRounds", "wackRounds",
    "approvedWackFileVersion", "approvedWackSha256", "approvedWackSignerSubject",
    "approvedWackSignerThumbprint", "approvedWackTestCount", "approvedWackTestInventorySha256",
    "submissionSignatureStatus", "submissionStatus", "certificationStatus",
    "storeSignsAfterSubmission", "qaCertificateIncluded", "publicGitHubAsset", "handoffVisibility"
) "Prepared Store lineage"
if ($Source.schemaVersion -ne 2 -or $Source.product -cne "Quant Scenario Studio by LAI ZEYU" -or
    $Source.author -cne "LAI ZEYU（来泽宇）" -or $Source.publisherDisplayName -cne "LAI ZEYU" -or
    $Source.partnerCenterProductId -cne "9NWTH4KJX5GW" -or
    $Source.packageIdentity -cne "LAIZEYU.QuantScenarioStudiobyLAIZEYU" -or
    $Source.technicalPublisher -cne "CN=A5F91D0A-30C6-48EE-944F-B767FA872BE8" -or
    [string]$Source.sourceCommit -cnotmatch '^[0-9a-f]{40}$' -or
    $Source.submissionPackageFile -cne "QuantScenarioStudio_1.5.0.0_x64_store-unsigned.msix" -or
    [long]$Source.submissionPackageSize -le 0 -or [int]$Source.payloadFileCount -le 0 -or
    [string]$Source.submissionPackageSha256 -cnotmatch '^[0-9a-f]{64}$' -or
    [string]$Source.qaCandidatePackageSha256 -cnotmatch '^[0-9a-f]{64}$' -or
    [string]$Source.payloadTreeSha256 -cnotmatch '^[0-9a-f]{64}$' -or
    [int]$Source.nativeQaRounds -ne 2 -or [int]$Source.wackRounds -ne 2 -or
    [string]$Source.approvedWackFileVersion -cnotmatch '^\d+\.\d+\.\d+\.\d+$' -or
    [string]$Source.approvedWackSha256 -cnotmatch '^[0-9a-f]{64}$' -or
    [string]::IsNullOrWhiteSpace([string]$Source.approvedWackSignerSubject) -or
    [string]$Source.approvedWackSignerSubject -match '[\r\n]' -or
    [string]$Source.approvedWackSignerThumbprint -cnotmatch '^[0-9a-f]{40}$' -or
    [int]$Source.approvedWackTestCount -lt 1 -or [int]$Source.approvedWackTestCount -gt 10000 -or
    [string]$Source.approvedWackTestInventorySha256 -cnotmatch '^[0-9a-f]{64}$' -or
    $Source.submissionSignatureStatus -cne "UNSIGNED_FOR_PARTNER_CENTER" -or
    $Source.submissionStatus -cne "NOT_SUBMITTED" -or $Source.certificationStatus -cne "NOT_CERTIFIED" -or
    -not $Source.storeSignsAfterSubmission -or $Source.qaCertificateIncluded -or $Source.publicGitHubAsset -or
    $Source.handoffVisibility -cne "LOCAL_FIXED_NTFS_EXACT_ACL_PENDING_RETENTION") {
    throw "Prepared Store lineage identity, hash, QA/WACK, or private-handoff status is malformed."
}
$HeadCommit = (& git -C $ProjectRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $HeadCommit -cne $Source.sourceCommit) {
    throw "Prepared Store lineage no longer matches the exact checked-out source commit."
}
$RunLeaf = "aegis-store-1.5.0-$env:GITHUB_RUN_ID-$env:GITHUB_RUN_ATTEMPT-$($Source.sourceCommit.Substring(0, 12))"
$RunRoot = Join-Path $ExactPrivateRoot $RunLeaf
$IncompleteRoot = Join-Path $ExactPrivateRoot ($RunLeaf + ".incomplete")
if ((Test-Path -LiteralPath $RunRoot) -or (Test-Path -LiteralPath $IncompleteRoot)) {
    throw "This exact private Store handoff run identity already exists."
}
$CreatedIncomplete = $false
$Completed = $false
try {
New-Item -ItemType Directory -Path $IncompleteRoot | Out-Null
$CreatedIncomplete = $true

$Security = [Security.AccessControl.DirectorySecurity]::new()
$Security.SetOwner([Security.Principal.SecurityIdentifier]::new($CurrentSid))
$Security.SetAccessRuleProtection($true, $false)
foreach ($SidText in $AllowedSids) {
    $Rule = [Security.AccessControl.FileSystemAccessRule]::new(
        [Security.Principal.SecurityIdentifier]::new($SidText),
        [Security.AccessControl.FileSystemRights]::FullControl,
        [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit',
        [Security.AccessControl.PropagationFlags]::None,
        [Security.AccessControl.AccessControlType]::Allow
    )
    [void]$Security.AddAccessRule($Rule)
}
Set-Acl -LiteralPath $IncompleteRoot -AclObject $Security
$RunAcl = Assert-ExactPrivateAcl -Path $IncompleteRoot -AllowedSids $AllowedSids -Label "Run-owned incomplete private handoff" -RequireProtected

$ExpectedStaging = @(
    "QuantScenarioStudio_1.5.0.0_x64_store-unsigned.msix",
    "STORE-SUBMISSION-SHA256.txt",
    "store-submission-lineage.json"
) | Sort-Object
$StagingItem = Get-Item -LiteralPath $StagingRoot -Force
$ActualStaging = @(Get-ChildItem -LiteralPath $StagingRoot -File -Force | ForEach-Object Name | Sort-Object)
if (($ActualStaging -join '|') -cne ($ExpectedStaging -join '|') -or
    @(Get-ChildItem -LiteralPath $StagingRoot -Directory -Force).Count -ne 0 -or
    (($StagingItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or
    @(Get-ChildItem -LiteralPath $StagingRoot -File -Force | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 }).Count -ne 0) {
    throw "Prepared Store handoff staging inventory is not exact."
}
$ExpectedChecksum = "$($Source.submissionPackageSha256)  $($Source.submissionPackageFile)`n"
if ([IO.File]::ReadAllText((Join-Path $StagingRoot "STORE-SUBMISSION-SHA256.txt"), [Text.Encoding]::UTF8) -cne $ExpectedChecksum) {
    throw "Prepared Store submission checksum is not canonical."
}
foreach ($Name in $ExpectedStaging) {
    Copy-Item -LiteralPath (Join-Path $StagingRoot $Name) -Destination (Join-Path $IncompleteRoot $Name)
}

$CopiedPackage = Join-Path $IncompleteRoot "QuantScenarioStudio_1.5.0.0_x64_store-unsigned.msix"
if ((Get-FileHash -Algorithm SHA256 -LiteralPath $CopiedPackage).Hash.ToLowerInvariant() -cne $Source.submissionPackageSha256 -or
    (Get-Item -LiteralPath $CopiedPackage).Length -ne [long]$Source.submissionPackageSize) {
    throw "ACL-protected Store handoff copy differs from the verified unsigned package."
}
$Signature = Get-AuthenticodeSignature -LiteralPath $CopiedPackage
if ($Signature.Status -ne [Management.Automation.SignatureStatus]::NotSigned -or $Signature.SignerCertificate) {
    throw "ACL-protected Partner Center handoff is not unsigned."
}
$RetainedFileRows = [Collections.Generic.List[object]]::new()
foreach ($File in @(Get-ChildItem -LiteralPath $IncompleteRoot -File -Force | Sort-Object Name)) {
    if (($File.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Private handoff contains a reparse-point file." }
    $FileAcl = Assert-ExactPrivateAcl -Path $File.FullName -AllowedSids $AllowedSids -Label $File.Name
    $FileAclSddl = $FileAcl.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::All)
    $RetainedFileRows.Add([ordered]@{
        name = $File.Name
        size = [long]$File.Length
        sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $File.FullName).Hash.ToLowerInvariant()
        aclSha256 = Get-TextSha256 $FileAclSddl
    })
}

$RootAclSddl = $RootAcl.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::All)
$RunAclSddl = $RunAcl.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::All)
$RootAclHash = Get-TextSha256 $RootAclSddl
$RunAclHash = Get-TextSha256 $RunAclSddl
$Receipt = [ordered]@{
    schemaVersion = 2
    product = "Quant Scenario Studio by LAI ZEYU"
    author = "LAI ZEYU（来泽宇）"
    githubRunId = $env:GITHUB_RUN_ID
    githubRunAttempt = $env:GITHUB_RUN_ATTEMPT
    sourceCommit = $Source.sourceCommit
    partnerCenterProductId = "9NWTH4KJX5GW"
    submissionPackageSha256 = $Source.submissionPackageSha256
    payloadTreeSha256 = $Source.payloadTreeSha256
    approvedWackFileVersion = $Source.approvedWackFileVersion
    approvedWackSha256 = $Source.approvedWackSha256
    approvedWackSignerSubject = $Source.approvedWackSignerSubject
    approvedWackSignerThumbprint = $Source.approvedWackSignerThumbprint
    approvedWackTestCount = [int]$Source.approvedWackTestCount
    approvedWackTestInventorySha256 = $Source.approvedWackTestInventorySha256
    rootAclSha256 = $RootAclHash
    handoffAclSha256 = $RunAclHash
    accessIdentityCount = $AllowedSids.Count
    retainedFiles = @($RetainedFileRows)
    storageBoundary = "LOCAL_FIXED_NTFS_EXACT_ACL"
    githubArtifactUploaded = $false
    retainedAt = [DateTimeOffset]::UtcNow.ToString("o")
}
$ReceiptPath = Join-Path $IncompleteRoot "private-handoff-receipt.json"
[IO.File]::WriteAllText($ReceiptPath, (($Receipt | ConvertTo-Json -Depth 6 -Compress) + "`n"), [Text.UTF8Encoding]::new($false))
[void](Assert-ExactPrivateAcl -Path $ReceiptPath -AllowedSids $AllowedSids -Label "private-handoff-receipt.json")
$FinalAcl = Assert-ExactPrivateAcl -Path $IncompleteRoot -AllowedSids $AllowedSids -Label "Frozen run-owned private handoff" -RequireProtected
$FinalAclSddl = $FinalAcl.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::All)
if ((Get-TextSha256 $FinalAclSddl) -cne $RunAclHash) { throw "Private handoff ACL changed while files were frozen." }
$FinalNames = @(Get-ChildItem -LiteralPath $IncompleteRoot -File -Force | ForEach-Object Name | Sort-Object)
$ExpectedFinal = @($ExpectedStaging + "private-handoff-receipt.json") | Sort-Object
if (($FinalNames -join '|') -cne ($ExpectedFinal -join '|') -or
    @(Get-ChildItem -LiteralPath $IncompleteRoot -Directory -Force).Count -ne 0) {
    throw "Final private Store handoff inventory is not exact."
}

# The final directory name is the completion marker. Directory.Move is a same-parent
# NTFS rename, so an observer can see either an explicitly incomplete run or the
# fully verified handoff, never a partially populated final handoff.
[IO.Directory]::Move($IncompleteRoot, $RunRoot)
$Completed = $true

if ($env:GITHUB_STEP_SUMMARY) {
    @(
        "",
        "### Private Store handoff retention",
        "",
        "- Unsigned submission SHA-256: ``$($Source.submissionPackageSha256)``",
        "- Payload tree SHA-256: ``$($Source.payloadTreeSha256)``",
        "- Local fixed NTFS exact-ACL retention: PASS",
        "- GitHub artifact uploaded: no",
        "- Submission/certification: not performed"
    ) | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Encoding utf8
}
Write-Host "Retained the verified unsigned Store handoff under the pre-provisioned local fixed-NTFS exact-ACL boundary; no path or package was uploaded to GitHub."
} catch {
    $Failure = $_
    if (-not $Completed -and $CreatedIncomplete -and (Test-Path -LiteralPath $IncompleteRoot)) {
        try {
            $IncompleteItem = Get-Item -LiteralPath $IncompleteRoot -Force
            $ParentMatches = $IncompleteItem.Parent.FullName.TrimEnd("\").Equals(
                $ExactPrivateRoot,
                [StringComparison]::OrdinalIgnoreCase
            )
            if (-not $ParentMatches -or $IncompleteItem.Name -cne ($RunLeaf + ".incomplete") -or
                (($IncompleteItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
                throw "The incomplete handoff cleanup boundary is not exact."
            }
            Remove-Item -LiteralPath $IncompleteRoot -Recurse -Force
        } catch {
            Write-Warning "The failed run's explicitly incomplete private handoff could not be safely removed; an administrator must inspect it."
        }
    }
    throw $Failure
}
