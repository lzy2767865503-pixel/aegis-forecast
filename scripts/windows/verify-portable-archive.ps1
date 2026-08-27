[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ArchivePath,
    [Parameter(Mandatory = $true)][string]$DestinationPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ExpectedProductDirectory = 'QuantScenarioStudio-by-LAI-ZEYU-1.5.0-x64'
$ExpectedPrefix = "$ExpectedProductDirectory/"
$MaximumEntryCount = 20000
$MaximumFileLength = 512MB
$MaximumExpandedLength = 2GB

function Get-CanonicalSha256([string]$Text) {
    return [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Text))
    ).ToLowerInvariant()
}

function Assert-SafeArchiveName([string]$OriginalName) {
    if ([string]::IsNullOrWhiteSpace($OriginalName) -or $OriginalName.IndexOf([char]0) -ge 0 -or
        $OriginalName.StartsWith('/') -or $OriginalName.StartsWith('\') -or
        $OriginalName -match '^[A-Za-z]:' -or $OriginalName.Contains(':')) {
        throw "Portable ZIP contains an absolute, device, ADS, or empty entry name."
    }
    $Normalized = $OriginalName.Replace('\', '/')
    if ($OriginalName -cne $Normalized -or $Normalized.Length -gt 4096 -or
        $Normalized -cne $Normalized.Normalize([Text.NormalizationForm]::FormC) -or
        $Normalized.IndexOfAny([char[]]@(0..31)) -ge 0 -or
        $Normalized.Contains('//')) {
        throw "Portable ZIP entry name is not canonical NFC with forward single separators and no controls."
    }
    $IsDirectory = $Normalized.EndsWith('/', [StringComparison]::Ordinal)
    $PathText = if ($IsDirectory) { $Normalized.Substring(0, $Normalized.Length - 1) } else { $Normalized }
    $Segments = @($PathText.Split('/'))
    if ($Segments.Count -lt 1 -or @($Segments | Where-Object {
        [string]::IsNullOrWhiteSpace($_) -or $_ -in @('.', '..') -or
        $_.Length -gt 255 -or $_.Trim() -cne $_ -or $_.TrimEnd(' ', '.') -cne $_ -or
        $_ -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?$'
    }).Count -ne 0) {
        throw "Portable ZIP contains traversal, empty, dot, or Windows-normalized path segments."
    }
    if (-not $Normalized.StartsWith($ExpectedPrefix, [StringComparison]::Ordinal) -and
        $Normalized -cne $ExpectedPrefix) {
        throw "Portable ZIP contains a root-level entry or a non-product top-level prefix."
    }
    return [pscustomobject]@{ name = $Normalized; isDirectory = $IsDirectory }
}

$ArchiveItem = Get-Item -LiteralPath $ArchivePath -Force
if (($ArchiveItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
    $ArchiveItem.Length -lt 1024 -or $ArchiveItem.Length -gt 1GB) {
    throw 'Portable ZIP file boundary is invalid.'
}
$Destination = [IO.Path]::GetFullPath($DestinationPath).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
if ([string]::IsNullOrWhiteSpace($Destination) -or [IO.Path]::GetPathRoot($Destination).TrimEnd([IO.Path]::DirectorySeparatorChar) -ceq $Destination -or
    (Test-Path -LiteralPath $Destination)) {
    throw 'Portable ZIP extraction destination must be a new non-volume-root directory.'
}
if ($IsWindows) {
    foreach ($StartPath in @($ArchiveItem.Directory.FullName, [IO.Path]::GetDirectoryName($Destination))) {
        if (-not (Test-Path -LiteralPath $StartPath -PathType Container)) { throw 'Portable ZIP path parent must already exist.' }
        $Ancestor = Get-Item -LiteralPath $StartPath -Force
        while ($Ancestor) {
            if (($Ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'Portable ZIP archive/extraction path has a reparse-point ancestor.'
            }
            $Ancestor = $Ancestor.Parent
        }
    }
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$Archive = [IO.Compression.ZipFile]::OpenRead($ArchiveItem.FullName)
$Rows = [Collections.Generic.List[object]]::new()
$Seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$PathNodes = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
$TotalExpanded = [long]0
$FileCount = 0
try {
    if ($Archive.Entries.Count -lt 2 -or $Archive.Entries.Count -gt $MaximumEntryCount) {
        throw 'Portable ZIP entry count is outside the strict bound.'
    }
    foreach ($Entry in $Archive.Entries) {
        $Safe = Assert-SafeArchiveName -OriginalName $Entry.FullName
        $CollisionKey = $Safe.name.TrimEnd('/')
        if (-not $Seen.Add($CollisionKey)) {
            throw "Portable ZIP contains a duplicate or case-colliding entry: $($Safe.name)"
        }
        $NodeSegments = @($CollisionKey.Split('/'))
        for ($NodeIndex = 0; $NodeIndex -lt $NodeSegments.Count; $NodeIndex++) {
            $NodePath = @($NodeSegments[0..$NodeIndex]) -join '/'
            $NodeKind = if ($NodeIndex -eq ($NodeSegments.Count - 1) -and -not $Safe.isDirectory) { 'file' } else { 'directory' }
            if ($PathNodes.ContainsKey($NodePath)) {
                $ExistingNode = $PathNodes[$NodePath]
                if ([string]$ExistingNode.path -cne $NodePath -or [string]$ExistingNode.type -cne $NodeKind) {
                    throw "Portable ZIP contains an implicit directory case collision or file/directory conflict: $NodePath"
                }
            } else {
                $PathNodes.Add($NodePath, [ordered]@{ path = $NodePath; type = $NodeKind })
            }
        }
        $External = [uint32]([int64]$Entry.ExternalAttributes -band 0xffffffffL)
        $UnixType = ($External -shr 16) -band 0xF000
        $DosAttributes = $External -band 0xFFFF
        if ($UnixType -eq 0xA000 -or $UnixType -notin @(0, 0x4000, 0x8000) -or
            ($Safe.isDirectory -and $UnixType -notin @(0, 0x4000)) -or
            (-not $Safe.isDirectory -and $UnixType -eq 0x4000) -or
            ($DosAttributes -band [uint32][IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Portable ZIP contains a symbolic-link, special-type, type-conflicting, or reparse entry: $($Safe.name)"
        }
        if ($Safe.isDirectory) {
            if ($Entry.Length -ne 0) { throw "Portable ZIP directory entry has content: $($Safe.name)" }
            $Rows.Add([ordered]@{ path = $Safe.name; type = 'directory'; size = 0; sha256 = '-' })
            continue
        }
        if ($Entry.Length -lt 0 -or $Entry.Length -gt $MaximumFileLength) {
            throw "Portable ZIP entry exceeds the strict per-file bound: $($Safe.name)"
        }
        $TotalExpanded += [long]$Entry.Length
        if ($TotalExpanded -gt $MaximumExpandedLength) { throw 'Portable ZIP exceeds the strict expanded-size bound.' }
        $Input = $Entry.Open()
        $Hasher = [Security.Cryptography.SHA256]::Create()
        try {
            $Buffer = New-Object byte[] 65536
            [long]$Observed = 0
            while (($Read = $Input.Read($Buffer, 0, $Buffer.Length)) -gt 0) {
                $Observed += $Read
                if ($Observed -gt $MaximumFileLength -or $Observed -gt [long]$Entry.Length) {
                    throw "Portable ZIP entry expanded beyond its declared bound: $($Safe.name)"
                }
                [void]$Hasher.TransformBlock($Buffer, 0, $Read, $null, 0)
            }
            [void]$Hasher.TransformFinalBlock([byte[]]::new(0), 0, 0)
            if ($Observed -ne [long]$Entry.Length) { throw "Portable ZIP entry length changed while read: $($Safe.name)" }
            $Hash = [Convert]::ToHexString($Hasher.Hash).ToLowerInvariant()
        } finally {
            $Hasher.Dispose()
            $Input.Dispose()
        }
        $Rows.Add([ordered]@{ path = $Safe.name; type = 'file'; size = [long]$Entry.Length; sha256 = $Hash })
        $FileCount++
    }
    if ($FileCount -lt 2 -or -not $PathNodes.ContainsKey($ExpectedProductDirectory) -or
        [string]$PathNodes[$ExpectedProductDirectory].path -cne $ExpectedProductDirectory -or
        [string]$PathNodes[$ExpectedProductDirectory].type -cne 'directory') {
        throw 'Portable ZIP must contain one exact product prefix and at least two files.'
    }

    New-Item -ItemType Directory -Path $Destination | Out-Null
    $DestinationPrefix = $Destination + [IO.Path]::DirectorySeparatorChar
    foreach ($Entry in $Archive.Entries) {
        $Safe = Assert-SafeArchiveName -OriginalName $Entry.FullName
        $RelativeWindows = $Safe.name.Replace('/', [IO.Path]::DirectorySeparatorChar)
        $Target = [IO.Path]::GetFullPath((Join-Path $Destination $RelativeWindows))
        if (-not $Target.StartsWith($DestinationPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Portable ZIP extraction target escaped its exact root: $($Safe.name)"
        }
        if ($Safe.isDirectory) {
            if (-not (Test-Path -LiteralPath $Target)) { New-Item -ItemType Directory -Path $Target | Out-Null }
            continue
        }
        $Parent = [IO.Path]::GetDirectoryName($Target)
        if (-not (Test-Path -LiteralPath $Parent)) { New-Item -ItemType Directory -Path $Parent | Out-Null }
        $Input = $Entry.Open()
        $Output = [IO.FileStream]::new($Target, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $Input.CopyTo($Output) } finally { $Output.Dispose(); $Input.Dispose() }
    }
} catch {
    if (Test-Path -LiteralPath $Destination) {
        $DestinationItem = Get-Item -LiteralPath $Destination -Force
        if (($DestinationItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
            Remove-Item -LiteralPath $Destination -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    throw
} finally {
    $Archive.Dispose()
}

$Extracted = @((Get-Item -LiteralPath $Destination -Force); Get-ChildItem -LiteralPath $Destination -Recurse -Force)
if (@($Extracted | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 }).Count -ne 0) {
    throw 'Portable ZIP extraction root contains a reparse point.'
}
$RootChildren = @(Get-ChildItem -LiteralPath $Destination -Force)
if ($RootChildren.Count -ne 1 -or -not $RootChildren[0].PSIsContainer -or
    $RootChildren[0].Name -cne $ExpectedProductDirectory) {
    throw 'Portable ZIP extraction root contains an extra root file or non-exact product directory.'
}
$ExpectedExtractedNodes = @($PathNodes.Values | Sort-Object path)
$ActualExtractedNodes = @((Get-Item -LiteralPath $RootChildren[0].FullName -Force); Get-ChildItem -LiteralPath $RootChildren[0].FullName -Recurse -Force) |
    ForEach-Object {
        [ordered]@{
            path = [IO.Path]::GetRelativePath($Destination, $_.FullName).Replace('\', '/')
            type = if ($_.PSIsContainer) { 'directory' } else { 'file' }
        }
    } | Sort-Object path
if ($ActualExtractedNodes.Count -ne $ExpectedExtractedNodes.Count) {
    throw 'Portable ZIP full extraction node count differs from the derived entry inventory.'
}
for ($Index = 0; $Index -lt $ExpectedExtractedNodes.Count; $Index++) {
    if ([string]$ActualExtractedNodes[$Index].path -cne [string]$ExpectedExtractedNodes[$Index].path -or
        [string]$ActualExtractedNodes[$Index].type -cne [string]$ExpectedExtractedNodes[$Index].type) {
        throw "Portable ZIP full extraction node inventory differs: $([string]$ActualExtractedNodes[$Index].path)"
    }
}
$ExpectedFiles = @($Rows | Where-Object type -ceq 'file' | Sort-Object path)
$ActualFiles = @(Get-ChildItem -LiteralPath $Destination -File -Recurse -Force | Sort-Object FullName)
if ($ActualFiles.Count -ne $ExpectedFiles.Count) { throw 'Portable ZIP extracted file count differs from its full entry inventory.' }
for ($Index = 0; $Index -lt $ExpectedFiles.Count; $Index++) {
    $Actual = $ActualFiles[$Index]
    $Relative = [IO.Path]::GetRelativePath($Destination, $Actual.FullName).Replace('\', '/')
    $Expected = $ExpectedFiles[$Index]
    if ($Relative -cne [string]$Expected.path -or [long]$Actual.Length -ne [long]$Expected.size -or
        (Get-FileHash -Algorithm SHA256 -LiteralPath $Actual.FullName).Hash.ToLowerInvariant() -cne [string]$Expected.sha256) {
        throw "Portable ZIP extraction differs from its full entry inventory: $Relative"
    }
}
$CanonicalInventory = (@($Rows | Sort-Object path | ForEach-Object {
    "$($_.type)`t$($_.size)`t$($_.sha256)`t$($_.path)"
}) -join "`n") + "`n"
$InventorySha256 = Get-CanonicalSha256 $CanonicalInventory

[pscustomobject]@{
    productRoot = $RootChildren[0].FullName
    entryCount = $Rows.Count
    fileCount = $FileCount
    expandedSize = $TotalExpanded
    inventorySha256 = $InventorySha256
    entries = @($Rows | Sort-Object path)
}
