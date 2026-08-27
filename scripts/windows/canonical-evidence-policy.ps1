Set-StrictMode -Version Latest

function Assert-AegisCanonicalEvidenceFile {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    $Bytes = [IO.File]::ReadAllBytes($Path)
    $Text = [Text.Encoding]::UTF8.GetString($Bytes)
    if ($Text -match "-----BEGIN|PRIVATE KEY|PKCS#12|PFX|ESIGNER_|PASSWORD|SECRET|TOKEN|TOTP" -or
        $Text -match "[A-Za-z0-9+/]{80,}={0,2}" -or $Text -match "[0-9a-fA-F]{65,}") { throw "Canonical summary contains a forbidden certificate, secret, base64 or oversized hexadecimal payload." }
    for ($Index = 0; $Index -lt $Bytes.Length - 1; $Index++) {
        if ($Bytes[$Index] -eq 0x4D -and $Bytes[$Index + 1] -eq 0x5A) { throw "Canonical summary embeds an MZ signature." }
        if ($Index -lt $Bytes.Length - 3 -and $Bytes[$Index] -eq 0x50 -and $Bytes[$Index + 1] -eq 0x4B -and $Bytes[$Index + 2] -eq 0x03 -and $Bytes[$Index + 3] -eq 0x04) { throw "Canonical summary embeds a ZIP/MSIX signature." }
    }
    $Value = $Text | ConvertFrom-Json
    $ExpectedKeys = @(
        "schemaVersion", "product", "author", "publisherDisplayName", "technicalPublisher",
        "storeIdentityName", "sourceCommit", "submissionPackageSha256", "qaCandidatePackageSha256",
        "payloadTreeSha256", "qa1PackageSha256", "qa2PackageSha256", "wack1PackageSha256",
        "wack2PackageSha256", "wack1ReportSha256", "wack2ReportSha256", "qaRounds", "wackRounds",
        "binariesPublished", "storeHandoffPrivate"
    )
    $ActualKeys = @($Value.PSObject.Properties.Name)
    if (@($ExpectedKeys | Where-Object { $_ -notin $ActualKeys }).Count -ne 0 -or @($ActualKeys | Where-Object { $_ -notin $ExpectedKeys }).Count -ne 0) { throw "Canonical evidence schema is not exact." }
    if ($Value.schemaVersion -ne 3 -or $Value.product -cne "Quant Scenario Studio by LAI ZEYU" -or
        $Value.author -cne "LAI ZEYU（来泽宇）" -or $Value.publisherDisplayName -cne "LAI ZEYU" -or
        $Value.technicalPublisher -cne "CN=A5F91D0A-30C6-48EE-944F-B767FA872BE8" -or
        $Value.storeIdentityName -cne "LAIZEYU.QuantScenarioStudiobyLAIZEYU" -or
        $Value.sourceCommit -cnotmatch "^[0-9a-f]{40}$" -or $Value.binariesPublished -or -not $Value.storeHandoffPrivate) { throw "Canonical evidence fixed identity/status fields are invalid." }
    foreach ($Name in @("submissionPackageSha256", "qaCandidatePackageSha256", "payloadTreeSha256", "qa1PackageSha256", "qa2PackageSha256", "wack1PackageSha256", "wack2PackageSha256", "wack1ReportSha256", "wack2ReportSha256")) {
        if ([string]$Value.$Name -cnotmatch "^[0-9a-f]{64}$") { throw "Canonical evidence hash field $Name is invalid." }
    }
    $Rounds = @($Value.qaRounds)
    if ($Rounds.Count -ne 2 -or $Rounds[0] -cne "PASS" -or $Rounds[1] -cne "PASS") { throw "Canonical evidence must prove exactly two PASS rounds." }
    $WackRounds = @($Value.wackRounds)
    if ($WackRounds.Count -ne 2 -or $WackRounds[0] -cne "PASS" -or $WackRounds[1] -cne "PASS") { throw "Canonical evidence must prove exactly two complete WACK PASS rounds." }
    foreach ($BoundName in @("qa1PackageSha256", "qa2PackageSha256", "wack1PackageSha256", "wack2PackageSha256")) {
        if ([string]$Value.$BoundName -cne [string]$Value.qaCandidatePackageSha256) { throw "Canonical evidence does not bind $BoundName to the one temporary QA candidate." }
    }
}
