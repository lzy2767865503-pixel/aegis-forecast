[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Thumbprint,
    [string[]]$StoreLocations = @("CurrentUser\My", "CurrentUser\Root", "CurrentUser\TrustedPeople")
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$ExpectedSubject = "CN=A5F91D0A-30C6-48EE-944F-B767FA872BE8"
$ExactThumbprint = $Thumbprint.Trim().ToUpperInvariant()
if ($ExactThumbprint -cnotmatch "^[0-9A-F]{40}$") {
    throw "Refusing certificate cleanup: exact SHA-1 thumbprint is missing or invalid."
}
foreach ($Location in $StoreLocations) {
    if ($Location -cnotin @("CurrentUser\My", "CurrentUser\Root", "CurrentUser\TrustedPeople")) {
        throw "Refusing unapproved certificate store location: $Location"
    }
}
$Errors = [Collections.Generic.List[string]]::new()
foreach ($Location in $StoreLocations) {
    $ExactPath = "Cert:\$Location\$ExactThumbprint"
    try {
        $Certificate = Get-Item -LiteralPath $ExactPath -ErrorAction SilentlyContinue
        if ($Certificate) {
            if ($Certificate.Thumbprint -cne $ExactThumbprint -or $Certificate.Subject -cne $ExpectedSubject) {
                throw "Refusing to delete a certificate whose identity does not match the CI development certificate."
            }
            Remove-Item -LiteralPath $ExactPath -Force -ErrorAction Stop
            Write-Host "Removed exact ephemeral certificate $ExactThumbprint from $Location."
        }
        if (Test-Path -LiteralPath $ExactPath) { throw "Exact ephemeral certificate remained after removal." }
    } catch {
        $Errors.Add("$Location`: $($_.Exception.Message)")
    }
}
if ($Errors.Count -ne 0) { throw "Certificate cleanup failures: $($Errors -join ' | ')" }
