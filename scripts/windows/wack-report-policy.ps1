Set-StrictMode -Version Latest

function Read-AegisCompleteWackReport {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    [xml]$ReportXml = Get-Content -Raw -LiteralPath $Path
    if (-not $ReportXml.DocumentElement -or $ReportXml.DocumentElement.LocalName -cne "REPORT") { throw "WACK XML root is not REPORT." }
    $RootOverall = [string]$ReportXml.DocumentElement.GetAttribute("OVERALL_RESULT")
    $PartialRun = [string]$ReportXml.DocumentElement.GetAttribute("PARTIAL_RUN")
    if ($RootOverall -cne "PASS" -or $PartialRun -cne "FALSE") { throw "WACK report is not a complete, non-partial overall PASS." }
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
    $ResultValues = [System.Collections.Generic.List[string]]::new()
    $ResultValues.Add($RootOverall)
    foreach ($Test in $Tests) {
        $DirectResults = @($Test.SelectNodes("./*[local-name()='RESULT']"))
        if ($DirectResults.Count -ne 1 -or $DirectResults[0].InnerText.Trim() -cne "PASS") { throw "Every WACK TEST must contain exactly one direct PASS result." }
        $ResultValues.Add("PASS")
    }
    foreach ($Node in @($ReportXml.SelectNodes("//*"))) {
        foreach ($Attribute in @($Node.Attributes)) {
            $NormalizedName = $Attribute.LocalName -replace "[_-]", ""
            if (($NormalizedName -ieq "result" -or $NormalizedName -ieq "overallresult") -and $Attribute.Value.Trim() -cne "PASS") { throw "WACK contains a non-PASS result attribute." }
        }
        $NormalizedElementName = $Node.LocalName -replace "[_-]", ""
        if (($NormalizedElementName -ieq "result" -or $NormalizedElementName -ieq "overallresult") -and $Node.InnerText -and $Node.InnerText.Trim() -cne "PASS") { throw "WACK contains a non-PASS result element." }
    }
    return @($ResultValues)
}
