Set-StrictMode -Version Latest

function Read-AegisCompleteWackReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ApprovedVersion
    )
    if ($ApprovedVersion -cnotmatch '^\d+\.\d+\.\d+\.\d+$') {
        throw "The protected approved WACK version is not an exact four-part file version."
    }
    $ReportItem = Get-Item -LiteralPath $Path -Force
    if ($ReportItem.Length -lt 256 -or $ReportItem.Length -gt 50MB -or
        ($ReportItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "WACK XML size or file boundary is invalid."
    }
    $Settings = [Xml.XmlReaderSettings]::new()
    $Settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
    $Settings.XmlResolver = $null
    $Settings.MaxCharactersInDocument = 50MB
    $Reader = [Xml.XmlReader]::Create($ReportItem.FullName, $Settings)
    try {
        $ReportXml = [Xml.XmlDocument]::new()
        $ReportXml.XmlResolver = $null
        $ReportXml.Load($Reader)
    } finally { $Reader.Dispose() }
    if (-not $ReportXml.DocumentElement -or $ReportXml.DocumentElement.LocalName -cne "REPORT") { throw "WACK XML root is not REPORT." }
    $RootOverall = [string]$ReportXml.DocumentElement.GetAttribute("OVERALL_RESULT")
    $PartialRun = [string]$ReportXml.DocumentElement.GetAttribute("PARTIAL_RUN")
    $LatestVersion = [string]$ReportXml.DocumentElement.GetAttribute("LATEST_VERSION")
    $ReportVersion = [string]$ReportXml.DocumentElement.GetAttribute("VERSION")
    if ($RootOverall -cne "PASS" -or $PartialRun -cne "FALSE" -or
        $LatestVersion -cne "TRUE" -or $ReportVersion -cne $ApprovedVersion) {
        throw "WACK report is not a complete, non-partial overall PASS from the exact protected latest approved version."
    }
    $RawReport = $ReportXml.OuterXml
    if ($RawReport -match '(?i)\b(?:warning|warned|skipped|not[\s_-]*run|not[\s_-]*executed|incomplete)\b' -or
        $RawReport -match '(?i)not\s+all\s+tests\s+were\s+run') {
        throw "WACK report contains a warning, skipped/not-run test, or incomplete-run marker."
    }
    $RequirementsRoots = @($ReportXml.DocumentElement.SelectNodes("./*[local-name()='REQUIREMENTS']"))
    $Requirements = @($ReportXml.DocumentElement.SelectNodes("./*[local-name()='REQUIREMENTS']/*[local-name()='REQUIREMENT']"))
    $AllRequirements = @($ReportXml.SelectNodes("//*[local-name()='REQUIREMENT']"))
    $Tests = @($ReportXml.SelectNodes("//*[local-name()='TEST']"))
    if ($RequirementsRoots.Count -ne 1 -or $Requirements.Count -lt 1 -or $Requirements.Count -ne $AllRequirements.Count -or $Tests.Count -lt 1) { throw "WACK report is missing its complete requirements/test tree." }
    $RequirementTests = [System.Collections.Generic.List[System.Xml.XmlNode]]::new()
    foreach ($Requirement in $Requirements) {
        $DescendantTests = @($Requirement.SelectNodes(".//*[local-name()='TEST']"))
        if ($DescendantTests.Count -lt 1) { throw "Every WACK REQUIREMENT must contain at least one TEST." }
        foreach ($Test in $DescendantTests) { $RequirementTests.Add($Test) }
    }
    if ($RequirementTests.Count -ne $Tests.Count) { throw "Every WACK TEST must belong to exactly one REQUIREMENT." }

    function ConvertTo-AegisWackSignal([string]$Value, [string]$Label) {
        $Normalized = (($Value.Trim().ToUpperInvariant() -replace '[_\-/]+', ' ') -replace '\s+', ' ')
        if ([string]::IsNullOrWhiteSpace($Normalized) -or
            $Normalized -match '(^|\s)(?:FAIL|FAILED|ERROR|WARNING|WARN|SKIPPED|INCOMPLETE)(\s|$)' -or
            $Normalized -match '^NOT (?:RUN|EXECUTED)$') {
            throw "$Label contains a failed, error, warning, skipped, not-run, or empty WACK signal."
        }
        if ($Normalized -in @('PASS', 'PASSED')) { return 'PASS' }
        if ($Normalized -in @('NOT APPLICABLE', 'N A', 'NA')) { return 'NOT APPLICABLE' }
        throw "$Label contains a non-whitelisted WACK STATUS/RESULT/OUTCOME value."
    }

    function Get-AegisDirectNodeSignals([Xml.XmlNode]$Node, [string]$Label) {
        $Signals = [Collections.Generic.List[object]]::new()
        foreach ($Attribute in @($Node.Attributes)) {
            $Name = ($Attribute.LocalName -replace '[_-]', '').ToUpperInvariant()
            if ($Name -in @('STATUS', 'RESULT', 'OUTCOME')) {
                $Signals.Add([pscustomobject]@{
                    source = "@$($Attribute.LocalName)"
                    canonical = ConvertTo-AegisWackSignal -Value ([string]$Attribute.Value) -Label $Label
                })
            }
        }
        foreach ($Child in @($Node.ChildNodes | Where-Object { $_.NodeType -eq [Xml.XmlNodeType]::Element })) {
            $Name = ($Child.LocalName -replace '[_-]', '').ToUpperInvariant()
            if ($Name -in @('STATUS', 'RESULT', 'OUTCOME')) {
                $Signals.Add([pscustomobject]@{
                    source = $Child.LocalName
                    canonical = ConvertTo-AegisWackSignal -Value ([string]$Child.InnerText) -Label $Label
                })
            }
        }
        if (@($Signals | ForEach-Object canonical | Sort-Object -Unique).Count -gt 1) {
            throw "$Label has conflicting direct STATUS/RESULT/OUTCOME values."
        }
        return @($Signals)
    }

    $ReportSignals = @(Get-AegisDirectNodeSignals -Node $ReportXml.DocumentElement -Label 'WACK REPORT')
    if (@($ReportSignals | Where-Object { $_.canonical -cne 'PASS' }).Count -ne 0) {
        throw 'WACK REPORT STATUS/RESULT/OUTCOME conflicts with its exact overall PASS.'
    }
    foreach ($Requirement in $Requirements) {
        [void](Get-AegisDirectNodeSignals -Node $Requirement -Label 'WACK REQUIREMENT')
    }
    $ResultValues = [System.Collections.Generic.List[string]]::new()
    $TestRows = [System.Collections.Generic.List[object]]::new()
    $SeenIndexes = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $SeenNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $ResultValues.Add($RootOverall)
    foreach ($Test in $Tests) {
        $IndexText = [string]$Test.GetAttribute("INDEX")
        $Name = [string]$Test.GetAttribute("NAME")
        if ($IndexText -cnotmatch '^(?:0|[1-9]\d*)$' -or [string]::IsNullOrWhiteSpace($Name) -or
            $Name -cne $Name.Trim() -or $Name.Length -gt 512) {
            throw "Every WACK TEST must have one canonical numeric INDEX and one non-empty NAME."
        }
        if (-not $SeenIndexes.Add($IndexText) -or -not $SeenNames.Add($Name)) {
            throw "WACK TEST INDEX and NAME values must each be unique."
        }
        $DirectResults = @($Test.SelectNodes("./*[local-name()='RESULT']"))
        if ($DirectResults.Count -ne 1) { throw "Every WACK TEST must contain exactly one direct result." }
        $TestSignals = @(Get-AegisDirectNodeSignals -Node $Test -Label "WACK TEST $IndexText")
        $Status = ConvertTo-AegisWackSignal -Value ([string]$DirectResults[0].InnerText) -Label "WACK TEST $IndexText RESULT"
        $CanonicalStatus = if ($Status -ceq 'PASS') { 'PASS' } else { 'NOT APPLICABLE' }
        if ($TestSignals.Count -lt 1 -or
            @($TestSignals | Where-Object { $_.canonical -cne $CanonicalStatus }).Count -ne 0) {
            throw "Every WACK TEST direct STATUS/RESULT/OUTCOME signal must agree."
        }
        $ResultValues.Add($CanonicalStatus)
        $TestRows.Add([ordered]@{ index = $IndexText; name = $Name; status = $CanonicalStatus })
    }
    $SortedRows = @($TestRows | Sort-Object { [System.Numerics.BigInteger]::Parse([string]$_.index, [Globalization.CultureInfo]::InvariantCulture) })
    foreach ($Node in @($ReportXml.SelectNodes("//*"))) {
        foreach ($Attribute in @($Node.Attributes)) {
            $NormalizedName = $Attribute.LocalName -replace "[_-]", ""
            if ($NormalizedName -ieq "overallresult" -and $Attribute.Value.Trim() -cne "PASS") { throw "WACK contains a non-PASS overall result attribute." }
            if ($NormalizedName -ieq "result") {
                $NormalizedAttributeResult = (($Attribute.Value.Trim().ToUpperInvariant() -replace '[_\-/]+', ' ') -replace '\s+', ' ')
                if ($NormalizedAttributeResult -notin @('PASS', 'PASSED', 'NOT APPLICABLE', 'N A', 'NA')) { throw "WACK contains a non-whitelisted result attribute." }
            }
        }
        $NormalizedElementName = $Node.LocalName -replace "[_-]", ""
        if ($NormalizedElementName -ieq "overallresult" -and $Node.InnerText -and $Node.InnerText.Trim() -cne "PASS") { throw "WACK contains a non-PASS overall result element." }
        if ($NormalizedElementName -ieq "result" -and $Node.InnerText) {
            $NormalizedElementResult = (($Node.InnerText.Trim().ToUpperInvariant() -replace '[_\-/]+', ' ') -replace '\s+', ' ')
            if ($NormalizedElementResult -notin @('PASS', 'PASSED', 'NOT APPLICABLE', 'N A', 'NA')) { throw "WACK contains a non-whitelisted result element." }
        }
    }
    $InventoryText = (@($SortedRows | ForEach-Object {
        "$($_.index)`t$($_.name)`t$($_.status)"
    }) -join "`n") + "`n"
    $Sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $InventoryHash = [Convert]::ToHexString(
            $Sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($InventoryText))
        ).ToLowerInvariant()
    } finally {
        $Sha256.Dispose()
    }
    return [pscustomobject]@{
        latestVersion = $true
        reportVersion = $ReportVersion
        testCount = $SortedRows.Count
        testInventorySha256 = $InventoryHash
        overallResults = @($ResultValues)
        tests = @($SortedRows)
    }
}
