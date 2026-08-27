[CmdletBinding()]
param()
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "wack-report-policy.ps1")
. (Join-Path $PSScriptRoot "canonical-evidence-policy.ps1")
$Root = Join-Path ([IO.Path]::GetTempPath()) ("aegis-policy-selftest-" + [Guid]::NewGuid().ToString("N"))
try {
    New-Item -ItemType Directory -Path $Root | Out-Null
    $ValidWack = Join-Path $Root "valid.xml"
    [IO.File]::WriteAllText($ValidWack, '<REPORT OVERALL_RESULT="PASS" PARTIAL_RUN="FALSE"><REQUIREMENTS><REQUIREMENT><TEST><RESULT>PASS</RESULT></TEST></REQUIREMENT></REQUIREMENTS></REPORT>')
    $Results = @(Read-AegisCompleteWackReport $ValidWack)
    if ($Results.Count -ne 2) { throw "Valid WACK fixture did not produce two PASS results." }
    foreach ($Fixture in @(
        '<REPORT OVERALL_RESULT="PASS" PARTIAL_RUN="TRUE"><REQUIREMENTS><REQUIREMENT><TEST><RESULT>PASS</RESULT></TEST></REQUIREMENT></REQUIREMENTS></REPORT>',
        '<REPORT OVERALL_RESULT="PASS" PARTIAL_RUN="FALSE"><REQUIREMENTS><REQUIREMENT><TEST><RESULT>SKIPPED</RESULT></TEST></REQUIREMENT></REQUIREMENTS></REPORT>',
        '<REPORT OVERALL_RESULT="PASS" PARTIAL_RUN="FALSE"><REQUIREMENTS><REQUIREMENT><TEST><RESULT>WARNING</RESULT></TEST></REQUIREMENT></REQUIREMENTS></REPORT>',
        '<REPORT OVERALL_RESULT="PASS" PARTIAL_RUN="FALSE"><REQUIREMENTS><REQUIREMENT><TEST><RESULT>NOT_RUN</RESULT></TEST></REQUIREMENT></REQUIREMENTS></REPORT>',
        '<REPORT OVERALL_RESULT="PASS" PARTIAL_RUN="FALSE"><MESSAGE>Not all tests were run during validation.</MESSAGE><REQUIREMENTS><REQUIREMENT><TEST><RESULT>PASS</RESULT></TEST></REQUIREMENT></REQUIREMENTS></REPORT>',
        '<REPORT OVERALL_RESULT="PASS" PARTIAL_RUN="FALSE"><REQUIREMENTS><REQUIREMENT><TEST EXECUTION_STATE="SKIPPED"><RESULT>PASS</RESULT></TEST></REQUIREMENT></REQUIREMENTS></REPORT>',
        '<REPORT OVERALL_RESULT="FAIL" PARTIAL_RUN="FALSE"><REQUIREMENTS><REQUIREMENT><TEST><RESULT>PASS</RESULT></TEST></REQUIREMENT></REQUIREMENTS></REPORT>',
        '<REPORT OVERALL_RESULT="PASS"><REQUIREMENTS><REQUIREMENT><TEST><RESULT>PASS</RESULT></TEST></REQUIREMENT></REQUIREMENTS></REPORT>',
        '<REPORT OVERALL_RESULT="PASS" PARTIAL_RUN="FALSE"><REQUIREMENTS><REQUIREMENT><TEST><RESULT>PASS</RESULT></TEST><TEST /></REQUIREMENT></REQUIREMENTS></REPORT>',
        '<REPORT OVERALL_RESULT="PASS" PARTIAL_RUN="FALSE"><REQUIREMENTS><REQUIREMENT></REQUIREMENT><REQUIREMENT><TEST><RESULT>PASS</RESULT></TEST></REQUIREMENT></REQUIREMENTS></REPORT>',
        '<REPORT OVERALL_RESULT="PASS" PARTIAL_RUN="FALSE"><REQUIREMENTS><REQUIREMENT><REQUIREMENT><TEST><RESULT>PASS</RESULT></TEST></REQUIREMENT></REQUIREMENT></REQUIREMENTS></REPORT>',
        '<REPORT OVERALL_RESULT="PASS" PARTIAL_RUN="FALSE"><REQUIREMENTS><REQUIREMENT><TEST><RESULT>PASS</RESULT></TEST></REQUIREMENT></REQUIREMENTS><TEST><RESULT>PASS</RESULT></TEST></REPORT>',
        '<REPORT OVERALL_RESULT="PASS" PARTIAL_RUN="FALSE"></REPORT>',
        '<OTHER OVERALL_RESULT="PASS" PARTIAL_RUN="FALSE"><REQUIREMENTS><REQUIREMENT><TEST><RESULT>PASS</RESULT></TEST></REQUIREMENT></REQUIREMENTS></OTHER>'
    )) {
        $Invalid = Join-Path $Root ([Guid]::NewGuid().ToString("N") + ".xml")
        [IO.File]::WriteAllText($Invalid, $Fixture)
        $Rejected = $false
        try { [void](Read-AegisCompleteWackReport $Invalid) } catch { $Rejected = $true }
        if (-not $Rejected) { throw "Invalid WACK fixture was accepted." }
    }
    $Canonical = [ordered]@{
        schemaVersion = 3; product = "Quant Scenario Studio by LAI ZEYU"; author = "LAI ZEYU（来泽宇）";
        publisherDisplayName = "LAI ZEYU"; technicalPublisher = "CN=A5F91D0A-30C6-48EE-944F-B767FA872BE8";
        storeIdentityName = "LAIZEYU.QuantScenarioStudiobyLAIZEYU"; sourceCommit = ("a" * 40);
        submissionPackageSha256 = ("d" * 64); qaCandidatePackageSha256 = ("b" * 64); payloadTreeSha256 = ("e" * 64);
        qa1PackageSha256 = ("b" * 64); qa2PackageSha256 = ("b" * 64); wack1PackageSha256 = ("b" * 64);
        wack2PackageSha256 = ("b" * 64); wack1ReportSha256 = ("c" * 64); wack2ReportSha256 = ("f" * 64);
        qaRounds = @("PASS", "PASS"); wackRounds = @("PASS", "PASS"); binariesPublished = $false; storeHandoffPrivate = $true
    }
    $ValidCanonical = Join-Path $Root "canonical.json"
    $Canonical | ConvertTo-Json -Compress | Set-Content -Encoding utf8 $ValidCanonical
    Assert-AegisCanonicalEvidenceFile $ValidCanonical
    $Canonical["storeIdentityName"] = "Other.ValidIdentity"
    $WrongIdentityCanonical = Join-Path $Root "wrong-identity.json"
    $Canonical | ConvertTo-Json -Compress | Set-Content -Encoding utf8 $WrongIdentityCanonical
    $Rejected = $false
    try { Assert-AegisCanonicalEvidenceFile $WrongIdentityCanonical } catch { $Rejected = $true }
    if (-not $Rejected) { throw "A non-production Partner Center Identity Name was accepted." }
    $Canonical["storeIdentityName"] = "LAIZEYU.QuantScenarioStudiobyLAIZEYU"
    $Canonical["unknown"] = "unexpected"
    $InvalidCanonical = Join-Path $Root "unknown.json"
    $Canonical | ConvertTo-Json -Compress | Set-Content -Encoding utf8 $InvalidCanonical
    $Rejected = $false
    try { Assert-AegisCanonicalEvidenceFile $InvalidCanonical } catch { $Rejected = $true }
    if (-not $Rejected) { throw "Unknown canonical evidence field was accepted." }
    $ForbiddenEvidenceFixtures = [ordered]@{
        "embedded-mz.data" = '{"x":"MZ"}'
        "embedded-zip.data" = "{`"x`":`"PK$([char]3)$([char]4)`"}"
        "private-key.data" = ('{"x":"-----BEGIN ' + 'PRIVATE' + ' KEY-----"}')
        "pkcs12.data" = '{"x":"PKCS#12"}'
        "secret.data" = '{"x":"ESIGNER_PASSWORD"}'
        "base64.data" = ('{"x":"' + ('A' * 80) + '"}')
        "hex.data" = ('{"x":"' + ('a' * 65) + '"}')
    }
    foreach ($Fixture in $ForbiddenEvidenceFixtures.GetEnumerator()) {
        $FixturePath = Join-Path $Root $Fixture.Key
        [IO.File]::WriteAllBytes($FixturePath, [Text.Encoding]::UTF8.GetBytes($Fixture.Value))
        $Rejected = $false
        try { Assert-AegisCanonicalEvidenceFile $FixturePath } catch { $Rejected = $true }
        if (-not $Rejected) { throw "Forbidden canonical evidence fixture was accepted: $($Fixture.Key)" }
    }

    $BackendRoot = Join-Path $Root "backend"
    $BackendManifest = Join-Path $Root "backend.sha256.json"
    New-Item -ItemType Directory -Path (Join-Path $BackendRoot "nested") | Out-Null
    [IO.File]::WriteAllText((Join-Path $BackendRoot "AegisBackend.exe"), "synthetic-test-binary")
    [IO.File]::WriteAllText((Join-Path $BackendRoot "nested\data.txt"), "stable-data")
    & (Join-Path $PSScriptRoot "backend-hashes.ps1") -Mode Write -BackendRootPath $BackendRoot -ManifestFilePath $BackendManifest
    & (Join-Path $PSScriptRoot "backend-hashes.ps1") -Mode Verify -BackendRootPath $BackendRoot -ManifestFilePath $BackendManifest
    [IO.File]::AppendAllText((Join-Path $BackendRoot "nested\data.txt"), "-tampered")
    $Rejected = $false
    try { & (Join-Path $PSScriptRoot "backend-hashes.ps1") -Mode Verify -BackendRootPath $BackendRoot -ManifestFilePath $BackendManifest } catch { $Rejected = $true }
    if (-not $Rejected) { throw "Mutated frozen-sidecar content passed the real hash verifier." }
} finally {
    if (Test-Path -LiteralPath $Root) { Remove-Item -LiteralPath $Root -Recurse -Force }
}
Write-Host "Behavioral policy self-test passed: WACK completeness, canonical-evidence boundaries and frozen-sidecar hashes reject malicious fixtures."
