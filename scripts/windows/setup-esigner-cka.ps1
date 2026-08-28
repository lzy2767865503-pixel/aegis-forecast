[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$WorkingRoot)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# Intentionally blocked. SSL.com eSigner CKA 1.0.8's repository-managed
# configuration path requires username/password/TOTP values in child-process
# arguments. Masking logs does not remove those values from the Windows process
# command line, so this repository must never automate that path.
foreach ($Name in @("SSL_ESIGNER_USERNAME", "SSL_ESIGNER_PASSWORD", "SSL_ESIGNER_TOTP_SECRET")) {
    $Value = [Environment]::GetEnvironmentVariable($Name, "Process")
    if ($Value) { Write-Output "::add-mask::$Value" }
}
if (-not $IsWindows -or -not [IO.Path]::IsPathFullyQualified($WorkingRoot)) {
    throw "The disabled repository CKA bootstrap received an invalid Windows working root."
}
throw @"
Fail-closed: repository-managed SSL.com CKA bootstrap is disabled because the
available vendor CLI credential configuration would expose static username,
password, or TOTP material in argv. Use only the separately administered,
hash-bound and Authenticode-bound no-checkout signer orchestrator. That
orchestrator must consume credentials through ENVIRONMENT_ONLY_NO_ARGV and emit
the exact cleanup receipt required by windows-github-release.yml; otherwise no
public Windows binary may be created.
"@
