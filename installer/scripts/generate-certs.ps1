#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Generates a self-signed TLS certificate for Remote Desktop Solution.

.PARAMETER InstDir
    The installation directory. Certificates are written to $InstDir\certs\.
    Defaults to $env:PROGRAMFILES\RemoteDesktop for standalone use.

.NOTES
    - Requires Windows 8.1 / Server 2012 R2 or later (New-SelfSignedCertificate).
    - Exports PFX (for .NET/Win32 use) and PEM files (for the Rust web server).
    - Attempts to detect the Tailscale IP and include it as an additional SAN.
#>
[CmdletBinding()]
param(
    [string]$InstDir = "$env:PROGRAMFILES\RemoteDesktop"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    Write-Host "[generate-certs] $Message" -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Message)
    Write-Host "[generate-certs] OK: $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[generate-certs] WARN: $Message" -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# Prepare directories
# ---------------------------------------------------------------------------
$CertsDir  = Join-Path $InstDir "certs"
$ConfigDir = Join-Path $InstDir "config"
New-Item -ItemType Directory -Force -Path $CertsDir  | Out-Null
New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null

# ---------------------------------------------------------------------------
# Build Subject Alternative Names list
# ---------------------------------------------------------------------------
Write-Step "Building SAN list..."

# Base SANs
$DnsNames = @("localhost")
$IpAddresses = @("127.0.0.1", "::1")

# Try to get the machine's LAN IP
try {
    $LanIp = (Get-NetIPAddress -AddressFamily IPv4 -PrefixOrigin Dhcp,Manual `
              -ErrorAction SilentlyContinue |
              Where-Object { $_.IPAddress -notmatch '^169\.' } |
              Sort-Object InterfaceMetric |
              Select-Object -First 1).IPAddress
    if ($LanIp) {
        $IpAddresses += $LanIp
        Write-Ok "Added LAN IP to SAN: $LanIp"
    }
}
catch {
    Write-Warn "Could not determine LAN IP: $_"
}

# Try to get Tailscale IP
$TailscaleIP = $null
try {
    $tailscaleExe = $null
    foreach ($candidate in @(
        "$env:ProgramFiles\Tailscale\tailscale.exe",
        "$env:ProgramFiles(x86)\Tailscale\tailscale.exe",
        (Get-Command "tailscale.exe" -ErrorAction SilentlyContinue)?.Source
    )) {
        if ($candidate -and (Test-Path $candidate)) {
            $tailscaleExe = $candidate
            break
        }
    }

    if ($tailscaleExe) {
        $rawIp = & $tailscaleExe ip -4 2>&1
        if ($LASTEXITCODE -eq 0 -and $rawIp -match '^\d{1,3}(\.\d{1,3}){3}') {
            $TailscaleIP = $rawIp.Trim()
            $IpAddresses += $TailscaleIP
            # Also add the MagicDNS hostname if available
            $rawHost = & $tailscaleExe status --json 2>&1 | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($rawHost -and $rawHost.Self -and $rawHost.Self.DNSName) {
                $DnsNames += ($rawHost.Self.DNSName.TrimEnd('.'))
            }
            Write-Ok "Added Tailscale IP to SAN: $TailscaleIP"
        }
        else {
            Write-Warn "tailscale ip -4 returned: $rawIp — skipping Tailscale SAN."
        }
    }
    else {
        Write-Warn "tailscale.exe not found; Tailscale IP will not be added to certificate SAN."
    }
}
catch {
    Write-Warn "Tailscale IP detection failed: $_"
}

# Build combined SAN string for New-SelfSignedCertificate
$SanEntries = ($DnsNames | ForEach-Object { "DNS=$_" }) +
              ($IpAddresses | ForEach-Object { "IPAddress=$_" })
Write-Step "SAN entries: $($SanEntries -join ', ')"

# ---------------------------------------------------------------------------
# Generate certificate
# ---------------------------------------------------------------------------
Write-Step "Generating self-signed certificate..."

# Remove any prior cert with the same subject to avoid accumulation
Get-ChildItem Cert:\LocalMachine\My |
    Where-Object { $_.Subject -eq "CN=localhost" -and $_.FriendlyName -eq "RemoteDesktopSolution" } |
    Remove-Item -ErrorAction SilentlyContinue

$cert = New-SelfSignedCertificate `
    -Subject           "CN=localhost" `
    -FriendlyName      "RemoteDesktopSolution" `
    -DnsName           $DnsNames `
    -IPAddress         ($IpAddresses | Select-Object -Unique) `
    -CertStoreLocation "Cert:\LocalMachine\My" `
    -KeyAlgorithm      RSA `
    -KeyLength         4096 `
    -HashAlgorithm     SHA256 `
    -KeyExportPolicy   Exportable `
    -NotAfter          (Get-Date).AddYears(10) `
    -KeyUsage          DigitalSignature, KeyEncipherment `
    -TextExtension     @("2.5.29.37={text}1.3.6.1.5.5.7.3.1")  # TLS Server Auth EKU

Write-Ok "Certificate created. Thumbprint: $($cert.Thumbprint)"

# ---------------------------------------------------------------------------
# Generate random PFX password and store it
# ---------------------------------------------------------------------------
Write-Step "Exporting PFX..."

$PfxPasswordFile = Join-Path $CertsDir ".pfx-password"
$PfxFile         = Join-Path $CertsDir "server.pfx"

# 32-byte random password, base64-encoded
$randomBytes  = New-Object byte[] 32
[System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($randomBytes)
$pfxPassword  = [Convert]::ToBase64String($randomBytes)
$pfxPassword  | Set-Content -Path $PfxPasswordFile -NoNewline -Encoding UTF8

# Restrict file permissions on the password file
$acl = Get-Acl $PfxPasswordFile
$acl.SetAccessRuleProtection($true, $false)
$adminSid   = [System.Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid
$adminPrincipal = New-Object System.Security.Principal.SecurityIdentifier($adminSid, $null)
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    $adminPrincipal,
    [System.Security.AccessControl.FileSystemRights]::FullControl,
    [System.Security.AccessControl.AccessControlType]::Allow
)
$acl.AddAccessRule($rule)
Set-Acl -Path $PfxPasswordFile -AclObject $acl

# Export PFX
$SecurePwd = ConvertTo-SecureString -String $pfxPassword -AsPlainText -Force
Export-PfxCertificate -Cert $cert -FilePath $PfxFile -Password $SecurePwd | Out-Null
Write-Ok "PFX exported to: $PfxFile"

# ---------------------------------------------------------------------------
# Export PEM certificate + private key for Rust web server
# ---------------------------------------------------------------------------
Write-Step "Exporting PEM certificate and key..."

$CrtFile = Join-Path $CertsDir "server.crt"
$KeyFile = Join-Path $CertsDir "server.key"

# Export the certificate (DER) then convert to PEM
$certBytes = $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
$b64Cert   = [Convert]::ToBase64String($certBytes, [System.Base64FormattingOptions]::InsertLineBreaks)
$pemCert   = "-----BEGIN CERTIFICATE-----`n$b64Cert`n-----END CERTIFICATE-----"
$pemCert   | Set-Content -Path $CrtFile -Encoding UTF8
Write-Ok "PEM certificate written to: $CrtFile"

# Export private key: use PFX round-trip, then extract via openssl if available,
# otherwise use .NET RSACng to export PKCS#8
$opensslExe = Get-Command "openssl" -ErrorAction SilentlyContinue
if ($opensslExe) {
    Write-Step "Extracting private key via openssl..."
    & openssl pkcs12 `
        -in    $PfxFile `
        -out   $KeyFile `
        -nocerts `
        -nodes `
        -passin "pass:$pfxPassword" `
        2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Ok "Private key extracted via openssl: $KeyFile"
    }
    else {
        Write-Warn "openssl pkcs12 returned $LASTEXITCODE; falling back to .NET RSA export."
        $opensslExe = $null
    }
}

if (-not $opensslExe) {
    Write-Step "Extracting private key via .NET RSA export..."
    try {
        $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert)
        $pkcs8 = $rsa.ExportPkcs8PrivateKey()
        $b64Key = [Convert]::ToBase64String($pkcs8, [System.Base64FormattingOptions]::InsertLineBreaks)
        $pemKey = "-----BEGIN PRIVATE KEY-----`n$b64Key`n-----END PRIVATE KEY-----"
        $pemKey | Set-Content -Path $KeyFile -Encoding UTF8
        Write-Ok "Private key exported (PKCS#8 PEM): $KeyFile"
    }
    catch {
        Write-Warn "Could not export private key via .NET: $_"
        Write-Warn "You may need to export the private key manually from Cert:\LocalMachine\My (Thumbprint: $($cert.Thumbprint))."
    }
}

# Restrict key file permissions
if (Test-Path $KeyFile) {
    $acl2 = Get-Acl $KeyFile
    $acl2.SetAccessRuleProtection($true, $false)
    $acl2.AddAccessRule($rule)
    Set-Acl -Path $KeyFile -AclObject $acl2
}

# ---------------------------------------------------------------------------
# Write cert thumbprint to config
# ---------------------------------------------------------------------------
Write-Step "Writing cert thumbprint to config..."

$ThumbprintFile = Join-Path $ConfigDir "cert-thumbprint.txt"
$cert.Thumbprint | Set-Content -Path $ThumbprintFile -Encoding UTF8
Write-Ok "Thumbprint written to: $ThumbprintFile"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "[generate-certs] Certificate summary:" -ForegroundColor Green
Write-Host "  Subject    : $($cert.Subject)"
Write-Host "  Thumbprint : $($cert.Thumbprint)"
Write-Host "  Valid until: $($cert.NotAfter)"
Write-Host "  SAN        : $($SanEntries -join ', ')"
Write-Host "  PFX        : $PfxFile"
Write-Host "  CRT        : $CrtFile"
Write-Host "  KEY        : $KeyFile"
Write-Host "  Thumbprint : $ThumbprintFile"
Write-Host ""
Write-Host "[generate-certs] Done." -ForegroundColor Green
