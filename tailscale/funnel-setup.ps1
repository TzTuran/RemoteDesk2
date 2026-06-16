<#
.SYNOPSIS
    Configures Tailscale Funnel to expose the Moonlight-Web frontend (port 8080)
    publicly over HTTPS on port 443 via Tailscale's global anycast network.

.DESCRIPTION
    1. Verifies Tailscale is installed and authenticated.
    2. Enables Tailscale Serve (HTTPS 443 → http://localhost:8080).
    3. Retrieves the public Funnel HTTPS URL.
    4. Writes the URL to $InstDir\config\tailscale-funnel-url.txt.
    5. Patches $InstDir\config\moonlight-web-config.json with the live hostname.
    6. Re-generates TLS certificates if the Tailscale IP has changed since the
       last run (delegates to generate-certs.ps1).

.PARAMETER InstDir
    Root installation directory.  Defaults to C:\RemoteDesktop.

.PARAMETER GenerateCertsScript
    Path to generate-certs.ps1.  Defaults to $InstDir\scripts\generate-certs.ps1.

.EXAMPLE
    .\funnel-setup.ps1 -InstDir "C:\RemoteDesktop"
#>

[CmdletBinding()]
param (
    [string]$InstDir           = "C:\RemoteDesktop",
    [string]$GenerateCertsScript = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-Step {
    param([string]$Message)
    Write-Host "`n[funnel-setup] $Message" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Write-Fail {
    param([string]$Message)
    Write-Host "[FAIL] $Message" -ForegroundColor Red
}

# Resolve default path for generate-certs.ps1
if (-not $GenerateCertsScript) {
    $GenerateCertsScript = Join-Path $InstDir "scripts\generate-certs.ps1"
}

# ---------------------------------------------------------------------------
# Step 1 — Verify Tailscale is installed
# ---------------------------------------------------------------------------

Write-Step "Checking Tailscale installation..."

$tailscaleBin = Get-Command "tailscale" -ErrorAction SilentlyContinue
if (-not $tailscaleBin) {
    # Try common install paths
    $candidates = @(
        "$env:ProgramFiles\Tailscale\tailscale.exe",
        "$env:ProgramFiles(x86)\Tailscale\tailscale.exe",
        "$env:LOCALAPPDATA\tailscale\tailscale.exe"
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) {
            $tailscaleBin = $c
            break
        }
    }
    if (-not $tailscaleBin) {
        Write-Fail "tailscale.exe not found. Install Tailscale from https://tailscale.com/download"
        exit 1
    }
}

$tailscaleExe = if ($tailscaleBin -is [string]) { $tailscaleBin } else { $tailscaleBin.Source }
Write-Success "Found tailscale at: $tailscaleExe"

# ---------------------------------------------------------------------------
# Step 2 — Verify Tailscale is authenticated / logged in
# ---------------------------------------------------------------------------

Write-Step "Checking Tailscale authentication status..."

try {
    $statusJson = & $tailscaleExe status --json 2>&1
    $status = $statusJson | ConvertFrom-Json
} catch {
    Write-Fail "Failed to parse 'tailscale status --json': $_"
    exit 1
}

if ($status.BackendState -ne "Running") {
    Write-Fail "Tailscale is not running (BackendState = $($status.BackendState))."
    Write-Host "Run 'tailscale up' or check the Tailscale system tray icon." -ForegroundColor Yellow
    exit 1
}

$selfNode = $status.Self
$tailscaleIP   = ($selfNode.TailscaleIPs | Where-Object { $_ -notmatch ":" } | Select-Object -First 1)
$tailscaleName = $selfNode.DNSName -replace "\.$", ""   # strip trailing dot

Write-Success "Tailscale is authenticated."
Write-Host "  Node name : $tailscaleName"
Write-Host "  IP        : $tailscaleIP"

# ---------------------------------------------------------------------------
# Step 3 — Enable Tailscale Serve (HTTPS 443 → http://localhost:8080)
# ---------------------------------------------------------------------------

Write-Step "Configuring Tailscale Serve: HTTPS 443 → http://localhost:8080 ..."

# 'tailscale serve' routes HTTPS traffic on port 443 to a local backend.
# '--bg' runs the serve config persistently across Tailscale restarts.
# 'funnel' is enabled separately as a node attribute in the ACL policy.
$serveArgs = @("serve", "--bg", "--https=443", "http://localhost:8080")

Write-Host "Running: tailscale $($serveArgs -join ' ')" -ForegroundColor DarkGray
$serveOutput = & $tailscaleExe @serveArgs 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Fail "tailscale serve failed (exit $LASTEXITCODE):`n$serveOutput"
    exit 1
}
Write-Success "Tailscale Serve configured."
Write-Host $serveOutput

# ---------------------------------------------------------------------------
# Step 4 — Enable Tailscale Funnel on port 443
# ---------------------------------------------------------------------------

Write-Step "Enabling Tailscale Funnel for port 443..."

$funnelArgs = @("funnel", "--bg", "443")
Write-Host "Running: tailscale $($funnelArgs -join ' ')" -ForegroundColor DarkGray
$funnelOutput = & $tailscaleExe @funnelArgs 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Fail "tailscale funnel failed (exit $LASTEXITCODE):`n$funnelOutput"
    exit 1
}
Write-Success "Tailscale Funnel enabled."
Write-Host $funnelOutput

# ---------------------------------------------------------------------------
# Step 5 — Retrieve the public Funnel URL
# ---------------------------------------------------------------------------

Write-Step "Retrieving public Funnel URL..."

# Try 'tailscale serve status' first, then fall back to constructing from DNS name
$publicUrl = $null

try {
    $serveStatusOutput = & $tailscaleExe serve status 2>&1
    # Parse a line containing the https URL, e.g.:
    #   https://hostname.tailnet-name.ts.net:443 (Funnel on)  ...
    $urlMatch = [regex]::Match(($serveStatusOutput -join "`n"), 'https://[^\s]+')
    if ($urlMatch.Success) {
        # Strip port 443 if present (it's implied)
        $publicUrl = $urlMatch.Value -replace ":443$", ""
    }
} catch {
    Write-Host "  (serve status parse failed, constructing URL from DNS name)" -ForegroundColor DarkGray
}

if (-not $publicUrl) {
    # Fallback: construct URL from MagicDNS hostname
    $publicUrl = "https://$tailscaleName"
}

Write-Success "Public Funnel URL: $publicUrl"

# ---------------------------------------------------------------------------
# Step 6 — Write URL to file
# ---------------------------------------------------------------------------

Write-Step "Writing URL to config file..."

$configDir    = Join-Path $InstDir "config"
$urlFile      = Join-Path $configDir "tailscale-funnel-url.txt"
$configFile   = Join-Path $configDir "moonlight-web-config.json"

if (-not (Test-Path $configDir)) {
    New-Item -ItemType Directory -Path $configDir -Force | Out-Null
}

$publicUrl | Set-Content -Path $urlFile -Encoding UTF8
Write-Success "URL written to: $urlFile"

# ---------------------------------------------------------------------------
# Step 7 — Patch moonlight-web-config.json with live hostname
# ---------------------------------------------------------------------------

Write-Step "Patching moonlight-web-config.json..."

if (Test-Path $configFile) {
    try {
        $config = Get-Content $configFile -Raw | ConvertFrom-Json

        # Extract just the hostname (strip scheme)
        $hostname = ($publicUrl -replace "^https://", "")

        $config.host = $hostname
        $config | ConvertTo-Json -Depth 10 | Set-Content -Path $configFile -Encoding UTF8
        Write-Success "moonlight-web-config.json updated (host = $hostname)."
    } catch {
        Write-Host "  WARNING: Could not patch $configFile — $_" -ForegroundColor Yellow
    }
} else {
    Write-Host "  INFO: $configFile not found; skipping patch." -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# Step 8 — Regenerate TLS certs if Tailscale IP changed
# ---------------------------------------------------------------------------

Write-Step "Checking if TLS certificate regeneration is needed..."

$ipCacheFile = Join-Path $configDir "last-tailscale-ip.txt"
$regenerateCerts = $false

if (Test-Path $ipCacheFile) {
    $cachedIp = (Get-Content $ipCacheFile -Raw).Trim()
    if ($cachedIp -ne $tailscaleIP) {
        Write-Host "  Tailscale IP changed: $cachedIp → $tailscaleIP" -ForegroundColor Yellow
        $regenerateCerts = $true
    } else {
        Write-Host "  Tailscale IP unchanged ($tailscaleIP). No cert regeneration needed."
    }
} else {
    Write-Host "  No cached IP found — triggering first-time cert generation." -ForegroundColor Yellow
    $regenerateCerts = $true
}

if ($regenerateCerts) {
    if (Test-Path $GenerateCertsScript) {
        Write-Step "Running generate-certs.ps1..."
        & $GenerateCertsScript -InstDir $InstDir -TailscaleIP $tailscaleIP -Hostname $tailscaleName
        if ($LASTEXITCODE -eq 0) {
            Write-Success "Certificates regenerated successfully."
        } else {
            Write-Host "  WARNING: generate-certs.ps1 exited with code $LASTEXITCODE." -ForegroundColor Yellow
        }
    } else {
        Write-Host "  WARNING: generate-certs.ps1 not found at: $GenerateCertsScript" -ForegroundColor Yellow
        Write-Host "  TLS SAN update skipped. Run generate-certs.ps1 manually." -ForegroundColor Yellow
    }

    # Update IP cache regardless of cert outcome
    $tailscaleIP | Set-Content -Path $ipCacheFile -Encoding UTF8
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

Write-Host "`n======================================================" -ForegroundColor White
Write-Host " Tailscale Funnel Setup Complete" -ForegroundColor Green
Write-Host "======================================================" -ForegroundColor White
Write-Host " Public URL  : $publicUrl" -ForegroundColor White
Write-Host " Tailscale IP: $tailscaleIP" -ForegroundColor White
Write-Host " Config dir  : $configDir" -ForegroundColor White
Write-Host "======================================================`n" -ForegroundColor White
