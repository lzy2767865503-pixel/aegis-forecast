[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SubmissionMsixPath,
    [Parameter(Mandatory = $true)][string]$QaMsixPath,
    [string]$ExpectedQaCertificateThumbprint = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
if (-not $IsWindows) { throw "MSIX submission/QA equivalence verification requires Windows." }
Add-Type -AssemblyName System.IO.Compression.FileSystem

$SubmissionPath = (Resolve-Path -LiteralPath $SubmissionMsixPath).Path
$QaPath = (Resolve-Path -LiteralPath $QaMsixPath).Path
if ($SubmissionPath.Equals($QaPath, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Unsigned submission and signed QA MSIX paths must be different files."
}
$ExpectedThumbprint = $ExpectedQaCertificateThumbprint.Trim().ToUpperInvariant()
if ($ExpectedThumbprint -and $ExpectedThumbprint -cnotmatch '^[0-9A-F]{40}$') { throw "Expected QA certificate thumbprint is invalid." }

function Get-MsixInventory {
    param([Parameter(Mandatory = $true)][string]$Path)
    $Archive = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $Rows = [Collections.Generic.List[object]]::new()
        $Seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $SignatureCount = 0
        $CodeIntegrityCount = 0
        [byte[]]$ContentTypesBytes = $null
        $TotalExpanded = [long]0
        foreach ($Entry in $Archive.Entries) {
            $Name = $Entry.FullName.Replace("\", "/")
            if ([string]::IsNullOrWhiteSpace($Name) -or [IO.Path]::IsPathRooted($Name) -or $Name.Split("/") -contains "..") {
                throw "MSIX contains an unsafe entry path: $Name"
            }
            if (-not $Seen.Add($Name.TrimEnd("/"))) { throw "MSIX contains a duplicate case-insensitive entry: $Name" }
            if ((($Entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) { throw "MSIX contains a symbolic-link entry: $Name" }
            $TotalExpanded += [long]$Entry.Length
            if ($Entry.Length -gt 536870912 -or $TotalExpanded -gt 4294967296) { throw "MSIX expanded content exceeds the bounded verification size." }
            if ($Name.Equals("AppxSignature.p7x", [StringComparison]::OrdinalIgnoreCase)) {
                if ($Name -cne "AppxSignature.p7x") { throw "MSIX signature entry must use the canonical AppxSignature.p7x path." }
                $SignatureCount++
                if ($Entry.Length -lt 8 -or $Entry.Length -gt 16777216) { throw "MSIX AppxSignature.p7x size is invalid." }
                continue
            }
            if ($Name.Equals("AppxMetadata/CodeIntegrity.cat", [StringComparison]::OrdinalIgnoreCase)) {
                if ($Name -cne "AppxMetadata/CodeIntegrity.cat") { throw "MSIX code-integrity catalog must use its canonical path." }
                $CodeIntegrityCount++
                if ($Entry.Length -lt 64 -or $Entry.Length -gt 16777216) { throw "MSIX CodeIntegrity.cat size is invalid." }
                continue
            }
            $Stream = $Entry.Open()
            $Hasher = [Security.Cryptography.SHA256]::Create()
            try {
                if ($Name -ceq "[Content_Types].xml") {
                    if ($Entry.Length -lt 32 -or $Entry.Length -gt 4194304) { throw "MSIX [Content_Types].xml size is invalid." }
                    $Buffer = [IO.MemoryStream]::new()
                    try {
                        $Stream.CopyTo($Buffer)
                        $ContentTypesBytes = $Buffer.ToArray()
                    } finally { $Buffer.Dispose() }
                    $Hash = [Convert]::ToHexString($Hasher.ComputeHash($ContentTypesBytes)).ToLowerInvariant()
                } else {
                    $Hash = [Convert]::ToHexString($Hasher.ComputeHash($Stream)).ToLowerInvariant()
                }
            }
            finally { $Hasher.Dispose(); $Stream.Dispose() }
            $Rows.Add([pscustomobject]@{ path = $Name; size = [long]$Entry.Length; sha256 = $Hash })
        }
        foreach ($Required in @("AppxManifest.xml", "AppxBlockMap.xml", "[Content_Types].xml")) {
            if (@($Rows | Where-Object { $_.path -ceq $Required }).Count -ne 1) { throw "MSIX must contain exactly one $Required entry." }
        }
        $Keys = [string[]]@($Rows | ForEach-Object path)
        [Array]::Sort($Keys, [StringComparer]::Ordinal)
        $ByPath = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
        foreach ($Row in $Rows) { $ByPath.Add([string]$Row.path, $Row) }
        $Canonical = (($Keys | ForEach-Object { $Row = $ByPath[$_]; "$($Row.sha256) $($Row.size) $($Row.path)" }) -join "`n") + "`n"
        $TreeHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Canonical))).ToLowerInvariant()
        return [pscustomobject]@{
            rows = @($Rows)
            signatureCount = $SignatureCount
            codeIntegrityCount = $CodeIntegrityCount
            contentTypesBytes = $ContentTypesBytes
            payloadFileCount = $Rows.Count
            payloadTreeSha256 = $TreeHash
        }
    } finally { $Archive.Dispose() }
}

function Get-ContentTypeMappings {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][string]$Label
    )
    if ($Bytes.Length -lt 32 -or $Bytes.Length -gt 4194304) { throw "$Label [Content_Types].xml byte length is invalid." }
    $Settings = [Xml.XmlReaderSettings]::new()
    $Settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
    $Settings.XmlResolver = $null
    $Settings.MaxCharactersInDocument = 4194304
    $Stream = [IO.MemoryStream]::new($Bytes, $false)
    $Reader = $null
    $Document = [Xml.XmlDocument]::new()
    $Document.PreserveWhitespace = $false
    $Document.XmlResolver = $null
    try {
        $Reader = [Xml.XmlReader]::Create($Stream, $Settings)
        $Document.Load($Reader)
    } catch {
        throw "$Label [Content_Types].xml is not safe, bounded XML: $($_.Exception.Message)"
    } finally {
        if ($Reader) { $Reader.Dispose() }
        $Stream.Dispose()
    }

    $Namespace = "http://schemas.openxmlformats.org/package/2006/content-types"
    $Root = $Document.DocumentElement
    if (-not $Root -or $Root.LocalName -cne "Types" -or $Root.NamespaceURI -cne $Namespace) {
        throw "$Label [Content_Types].xml root is invalid."
    }
    foreach ($Attribute in @($Root.Attributes)) {
        if ($Attribute.NamespaceURI -cne "http://www.w3.org/2000/xmlns/") {
            throw "$Label [Content_Types].xml root has an unsupported attribute: $($Attribute.Name)"
        }
    }

    $Rows = [Collections.Generic.List[object]]::new()
    $Seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($Node in @($Root.ChildNodes)) {
        if ($Node.NodeType -in @([Xml.XmlNodeType]::Whitespace, [Xml.XmlNodeType]::SignificantWhitespace)) { continue }
        if ($Node.NodeType -ne [Xml.XmlNodeType]::Element -or $Node.NamespaceURI -cne $Namespace -or
            $Node.LocalName -notin @("Default", "Override")) {
            throw "$Label [Content_Types].xml contains an unsupported child node."
        }
        $ExpectedTargetAttribute = if ($Node.LocalName -ceq "Default") { "Extension" } else { "PartName" }
        if ($Node.Attributes.Count -ne 2) { throw "$Label content-type mapping must have exactly two attributes." }
        foreach ($Attribute in @($Node.Attributes)) {
            if ($Attribute.NamespaceURI -or $Attribute.LocalName -notin @($ExpectedTargetAttribute, "ContentType")) {
                throw "$Label content-type mapping has an unsupported attribute: $($Attribute.Name)"
            }
        }
        $Target = [string]$Node.GetAttribute($ExpectedTargetAttribute)
        $ContentType = [string]$Node.GetAttribute("ContentType")
        if ($Target -cne $Target.Trim() -or $ContentType -cne $ContentType.Trim() -or
            [string]::IsNullOrWhiteSpace($Target) -or [string]::IsNullOrWhiteSpace($ContentType) -or
            $Target.Length -gt 1024 -or $ContentType.Length -gt 256 -or $ContentType -notmatch '^[^\s/;]+/[^\s;]+$') {
            throw "$Label content-type mapping values are invalid."
        }
        if ($Node.LocalName -ceq "Default") {
            if ($Target -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$') { throw "$Label default extension is invalid: $Target" }
        } elseif (-not $Target.StartsWith("/", [StringComparison]::Ordinal) -or $Target.Contains("\") -or
            $Target.Contains("//") -or $Target.Split("/") -contains "..") {
            throw "$Label override part name is invalid: $Target"
        }
        $Key = "$($Node.LocalName)|$Target"
        if (-not $Seen.Add($Key)) { throw "$Label contains a duplicate case-insensitive content-type mapping: $Key" }
        $Rows.Add([pscustomobject]@{
                key = $Key
                kind = [string]$Node.LocalName
                target = $Target
                contentType = $ContentType
            })
    }
    if ($Rows.Count -lt 1) { throw "$Label [Content_Types].xml has no mappings." }
    return @($Rows)
}

function Get-SigningFootprintMappingRole {
    param([Parameter(Mandatory = $true)][object]$Mapping)
    if ($Mapping.contentType -ceq "application/vnd.ms-appx.signature" -and
        (($Mapping.kind -ceq "Default" -and $Mapping.target.Equals("p7x", [StringComparison]::OrdinalIgnoreCase)) -or
         ($Mapping.kind -ceq "Override" -and $Mapping.target.Equals("/AppxSignature.p7x", [StringComparison]::OrdinalIgnoreCase)))) {
        return "signature"
    }
    if ($Mapping.contentType -ceq "application/vnd.ms-pkiseccat" -and
        (($Mapping.kind -ceq "Default" -and $Mapping.target.Equals("cat", [StringComparison]::OrdinalIgnoreCase)) -or
         ($Mapping.kind -ceq "Override" -and $Mapping.target.Equals("/AppxMetadata/CodeIntegrity.cat", [StringComparison]::OrdinalIgnoreCase)))) {
        return "codeIntegrity"
    }
    return ""
}

function Assert-ContentTypesSigningEquivalence {
    param(
        [Parameter(Mandatory = $true)][byte[]]$SubmissionBytes,
        [Parameter(Mandatory = $true)][byte[]]$QaBytes
    )
    $SubmissionMappings = @(Get-ContentTypeMappings -Bytes $SubmissionBytes -Label "Unsigned submission")
    $QaMappings = @(Get-ContentTypeMappings -Bytes $QaBytes -Label "Signed QA")
    $SubmissionByKey = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($Mapping in $SubmissionMappings) {
        if (Get-SigningFootprintMappingRole -Mapping $Mapping) {
            throw "Unsigned submission predeclares a signing-footprint content type: $($Mapping.key)"
        }
        $SubmissionByKey.Add([string]$Mapping.key, $Mapping)
    }
    $QaByKey = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
    $SignatureMappings = 0
    $CodeIntegrityMappings = 0
    foreach ($Mapping in $QaMappings) {
        $QaByKey.Add([string]$Mapping.key, $Mapping)
        if ($SubmissionByKey.ContainsKey([string]$Mapping.key)) {
            $SubmissionMapping = $SubmissionByKey[[string]$Mapping.key]
            if ([string]$SubmissionMapping.contentType -cne [string]$Mapping.contentType) {
                throw "SignTool changed an existing content-type mapping: $($Mapping.key)"
            }
            continue
        }
        $Role = Get-SigningFootprintMappingRole -Mapping $Mapping
        if ($Role -ceq "signature") { $SignatureMappings++; continue }
        if ($Role -ceq "codeIntegrity") { $CodeIntegrityMappings++; continue }
        throw "Signed QA MSIX added an unexpected content-type mapping: $($Mapping.key)"
    }
    foreach ($Mapping in $SubmissionMappings) {
        if (-not $QaByKey.ContainsKey([string]$Mapping.key)) {
            throw "SignTool removed an unsigned-submission content-type mapping: $($Mapping.key)"
        }
    }
    if ($QaMappings.Count -ne ($SubmissionMappings.Count + 2) -or
        $SignatureMappings -ne 1 -or $CodeIntegrityMappings -ne 1) {
        throw "Signed QA [Content_Types].xml must add exactly one signature mapping and one CodeIntegrity.cat mapping."
    }
}

$SubmissionInventory = Get-MsixInventory -Path $SubmissionPath
$QaInventory = Get-MsixInventory -Path $QaPath
if ($SubmissionInventory.signatureCount -ne 0) { throw "Partner Center submission MSIX must remain unsigned and contain no AppxSignature.p7x." }
if ($QaInventory.signatureCount -ne 1) { throw "Temporary QA MSIX must contain exactly one AppxSignature.p7x." }
if ($SubmissionInventory.codeIntegrityCount -ne 0) { throw "Partner Center submission MSIX must contain no signing-generated CodeIntegrity.cat." }
if ($QaInventory.codeIntegrityCount -ne 1) { throw "Temporary QA MSIX must contain exactly one signing-generated CodeIntegrity.cat." }
$SubmissionByPath = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
foreach ($Row in $SubmissionInventory.rows) { $SubmissionByPath.Add([string]$Row.path, $Row) }
$QaByPath = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
foreach ($Row in $QaInventory.rows) { $QaByPath.Add([string]$Row.path, $Row) }
if ($SubmissionInventory.payloadFileCount -ne $QaInventory.payloadFileCount) {
    throw "Unsigned submission and signed QA MSIX common payload file counts differ."
}
$ContentTypesPath = "[Content_Types].xml"
$Differences = [Collections.Generic.List[string]]::new()
foreach ($Path in @($SubmissionByPath.Keys | Sort-Object)) {
    if (-not $QaByPath.ContainsKey($Path)) { $Differences.Add("missing:$Path"); continue }
    if ($Path -ceq $ContentTypesPath) { continue }
    $Left = $SubmissionByPath[$Path]
    $Right = $QaByPath[$Path]
    if ([long]$Left.size -ne [long]$Right.size -or [string]$Left.sha256 -cne [string]$Right.sha256) {
        $Differences.Add("changed:$Path")
    }
}
foreach ($Path in @($QaByPath.Keys | Sort-Object)) {
    if (-not $SubmissionByPath.ContainsKey($Path)) { $Differences.Add("added:$Path") }
}
if ($Differences.Count -ne 0) {
    $Preview = @($Differences | Select-Object -First 20) -join ', '
    throw "Unsigned submission and signed QA application payload differ in $($Differences.Count) entries: $Preview"
}
Assert-ContentTypesSigningEquivalence `
    -SubmissionBytes $SubmissionInventory.contentTypesBytes `
    -QaBytes $QaInventory.contentTypesBytes

$SubmissionSignature = Get-AuthenticodeSignature -LiteralPath $SubmissionPath
if ($SubmissionSignature.Status -ne [Management.Automation.SignatureStatus]::NotSigned -or $SubmissionSignature.SignerCertificate) {
    throw "Partner Center handoff MSIX is not provably unsigned."
}
$QaSignature = Get-AuthenticodeSignature -LiteralPath $QaPath
if ($QaSignature.Status -notin @(
        [Management.Automation.SignatureStatus]::Valid,
        [Management.Automation.SignatureStatus]::UnknownError
    ) -or -not $QaSignature.SignerCertificate -or
    ($ExpectedThumbprint -and $QaSignature.SignerCertificate.Thumbprint -cne $ExpectedThumbprint)) {
    throw "Temporary QA MSIX does not expose the expected technical-Publisher development signature."
}

return [pscustomobject]@{
    submissionPackageSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $SubmissionPath).Hash.ToLowerInvariant()
    submissionPackageSize = (Get-Item -LiteralPath $SubmissionPath).Length
    qaPackageSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $QaPath).Hash.ToLowerInvariant()
    qaPackageSize = (Get-Item -LiteralPath $QaPath).Length
    payloadFileCount = $SubmissionInventory.payloadFileCount
    payloadTreeSha256 = $SubmissionInventory.payloadTreeSha256
}
