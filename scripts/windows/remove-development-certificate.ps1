[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Thumbprint,
    [string[]]$StoreLocations = @("CurrentUser\My", "CurrentUser\Root", "CurrentUser\TrustedPeople"),
    [switch]$DeletePrivateKey,
    [string]$ExpectedCngKeyName,
    [string]$ExpectedCngKeyUniqueName,
    [string]$ExpectedCngProvider
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
if ($DeletePrivateKey) {
    if ('CurrentUser\My' -cnotin $StoreLocations -or
        [string]::IsNullOrWhiteSpace($ExpectedCngKeyName) -or
        [string]::IsNullOrWhiteSpace($ExpectedCngKeyUniqueName) -or
        [IO.Path]::GetFileName($ExpectedCngKeyUniqueName) -cne $ExpectedCngKeyUniqueName -or
        $ExpectedCngProvider -cne 'Microsoft Software Key Storage Provider') {
        throw "Private-key deletion requires exact CurrentUser My CNG key/container evidence."
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
            if ($Location -ceq 'CurrentUser\My' -and $Certificate.HasPrivateKey) {
                if (-not $DeletePrivateKey) { throw "CurrentUser My development certificate cleanup must use Remove-Item -DeleteKey." }
                $PrivateKey = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($Certificate)
                try {
                    if ($PrivateKey -isnot [Security.Cryptography.RSACng] -or
                        $PrivateKey.Key.KeyName -cne $ExpectedCngKeyName -or
                        $PrivateKey.Key.UniqueName -cne $ExpectedCngKeyUniqueName -or
                        $PrivateKey.Key.Provider.Provider -cne $ExpectedCngProvider -or
                        $PrivateKey.Key.IsMachineKey) {
                        throw "Development certificate private key is not the exact expected current-user CNG container."
                    }
                } finally {
                    if ($PrivateKey) { $PrivateKey.Dispose() }
                }
                Remove-Item -LiteralPath $ExactPath -DeleteKey -Force -ErrorAction Stop
            } else {
                Remove-Item -LiteralPath $ExactPath -Force -ErrorAction Stop
            }
            Write-Host "Removed exact ephemeral certificate $ExactThumbprint from $Location."
        }
        if (Test-Path -LiteralPath $ExactPath) { throw "Exact ephemeral certificate remained after removal." }
    } catch {
        $Errors.Add("$Location`: $($_.Exception.Message)")
    }
}
if ($DeletePrivateKey) {
    $Provider = [Security.Cryptography.CngProvider]::new($ExpectedCngProvider)
    if ([Security.Cryptography.CngKey]::Exists($ExpectedCngKeyName, $Provider, [Security.Cryptography.CngKeyOpenOptions]::UserKey)) {
        $Errors.Add("CNG: exact development key container remains after Remove-Item -DeleteKey")
    }
    $UserKeyPath = Join-Path (Join-Path $env:APPDATA 'Microsoft\Crypto\Keys') $ExpectedCngKeyUniqueName
    if (Test-Path -LiteralPath $UserKeyPath) {
        $Errors.Add("CNG: exact development key file remains after Remove-Item -DeleteKey")
    }
}
if ($Errors.Count -ne 0) { throw "Certificate cleanup failures: $($Errors -join ' | ')" }
