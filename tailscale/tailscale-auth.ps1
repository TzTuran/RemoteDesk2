<#
.SYNOPSIS
    Interactive Tailscale authentication for a remote desktop server node.

.DESCRIPTION
    1. Checks if the device is already authenticated by inspecting tailscale status.
    2. If unauthenticated, launches 'tailscale up --qr' and displays the QR auth URL.
    3. Polls tailscale status every 2 seconds until authenticated (up to 120 seconds).
    4. On success, prints the node name, Tailscale IP, and MagicDNS hostname.
    5. Applies server-mode flags: --accept-dns, --shields-up=false.
    6. Optionally applies an auth key for headless / unattended installs.

.PARAMETER AuthKey
    Optional Tailscale auth key (tskey-...) for non-interactive / headless auth.
    If provided, skips QR code flow.  Generate at https://login.tailscale.com/admin/settings/keys.

.PARAMETER Hostname
    Optional node hostname to set in Tailscale (overrides OS hostname).

.PARAMETER Timeout
    Seconds to wait for interactive auth. Default: 120.

.EXAMPLE
    # Interactive auth with QR code
    .\tailscale-auth.ps1

.EXAMPLE
    # Headless auth with pre-generated key
    .\tailscale-auth.ps1 -AuthKey "tskey-auth-XXXX"
#>

[CmdletBinding()]
param (
    [string]$AuthKey  = "",
    [string]$Hostname = "",
    [int]$Timeout     = 120
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-Step    { param([string]$Msg) Write-Host "`n[tailscale-auth] $Msg" -ForegroundColor Cyan }
function Write-Success { param([string]$Msg) Write-Host "[OK]   $Msg" -ForegroundColor Green }
function Write-Info    { param([string]$Msg) Write-Host "[INFO] $Msg" -ForegroundColor White }
function Write-Warn    { param([string]$Msg) Write-Host "[WARN] $Msg" -ForegroundColor Yellow }
function Write-Fail    { param([string]$Msg) Write-Host "[FAIL] $Msg" -ForegroundColor Red }

function Get-TailscaleExe {
    $found = Get-Command "tailscale" -ErrorAction SilentlyContinue
    if ($found) { return $found.Source }

    $candidates = @(
        "$env:ProgramFiles\Tailscale\tailscale.exe",
        "$env:ProgramFiles(x86)\Tailscale\tailscale.exe",
        "$env:LOCALAPPDATA\tailscale\tailscale.exe"
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { return $c }
    }
    return $null
}

function Get-TailscaleStatus {
    param([string]$Exe)
    try {
        $json = & $Exe status --json 2>&1
        return ($json | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Test-TailscaleAuthenticated {
    param($StatusObj)
    if (-not $StatusObj) { return $false }
    return ($StatusObj.BackendState -eq "Running")
}

# ---------------------------------------------------------------------------
# Step 1 — Locate tailscale.exe
# ---------------------------------------------------------------------------

Write-Step "Locating Tailscale..."

$tsExe = Get-TailscaleExe
if (-not $tsExe) {
    Write-Fail "tailscale.exe not found. Download from: https://tailscale.com/download/windows"
    exit 1
}
Write-Success "Found: $tsExe"

# Also locate tailscaled / the Tailscale service check
$tsVersion = & $tsExe version 2>&1 | Select-Object -First 1
Write-Info "Tailscale version: $tsVersion"

# ---------------------------------------------------------------------------
# Step 2 — Check current authentication state
# ---------------------------------------------------------------------------

Write-Step "Checking current Tailscale authentication state..."

$currentStatus = Get-TailscaleStatus -Exe $tsExe

if (Test-TailscaleAuthenticated -StatusObj $currentStatus) {
    $selfNode      = $currentStatus.Self
    $nodeIP        = ($selfNode.TailscaleIPs | Where-Object { $_ -notmatch ":" } | Select-Object -First 1)
    $nodeDns       = $selfNode.DNSName -replace "\.$", ""
    $nodeHostname  = $selfNode.HostName

    Write-Success "Already authenticated!"
    Write-Host ""
    Write-Host "  Node hostname : $nodeHostname"
    Write-Host "  Tailscale IP  : $nodeIP"
    Write-Host "  MagicDNS name : $nodeDns"
    Write-Host ""

    # Still apply server-mode flags to ensure correct configuration
    Write-Step "Applying server-mode flags (accept-dns, shields-up=false)..."
    $upArgs = @("up", "--accept-dns", "--shields-up=false", "--accept-routes")
    if ($Hostname) { $upArgs += "--hostname=$Hostname" }
    & $tsExe @upArgs 2>&1 | Out-Null
    Write-Success "Server-mode flags applied."
    exit 0
}

Write-Info "Not yet authenticated (BackendState = $($currentStatus.BackendState))."

# ---------------------------------------------------------------------------
# Step 3 — Authenticate
# ---------------------------------------------------------------------------

Write-Step "Starting Tailscale authentication..."

# Build 'tailscale up' arguments
$upArgs = @(
    "up",
    "--accept-dns",
    "--shields-up=false",
    "--accept-routes"
)

if ($Hostname)  { $upArgs += "--hostname=$Hostname" }

if ($AuthKey) {
    # Headless / unattended auth via pre-generated key
    Write-Info "Using auth key for headless authentication..."
    $upArgs += "--authkey=$AuthKey"

    Write-Host "Running: tailscale up [auth key redacted]" -ForegroundColor DarkGray
    $upOutput = & $tsExe @upArgs 2>&1
    Write-Host $upOutput

    if ($LASTEXITCODE -ne 0) {
        Write-Fail "tailscale up with auth key failed (exit $LASTEXITCODE)."
        exit 1
    }
} else {
    # Interactive QR-code auth
    Write-Info "Launching interactive authentication with QR code..."
    Write-Host ""
    Write-Host "  Scan the QR code with the Tailscale mobile app, or click the URL." -ForegroundColor Yellow
    Write-Host "  (Waiting up to $Timeout seconds for you to complete auth...)" -ForegroundColor Yellow
    Write-Host ""

    # Start tailscale up --qr in background — it will print the auth URL + QR code
    $upArgs += "--qr"
    $tsProcess = Start-Process -FilePath $tsExe `
                               -ArgumentList $upArgs `
                               -NoNewWindow `
                               -PassThru

    # Poll for completion
    $elapsed   = 0
    $pollEvery = 2   # seconds
    $authDone  = $false

    while ($elapsed -lt $Timeout) {
        Start-Sleep -Seconds $pollEvery
        $elapsed += $pollEvery

        $pollStatus = Get-TailscaleStatus -Exe $tsExe
        if (Test-TailscaleAuthenticated -StatusObj $pollStatus) {
            $authDone = $true
            break
        }

        # Show simple progress indicator
        $remaining = $Timeout - $elapsed
        Write-Host "  Waiting... ($remaining s remaining)" -ForegroundColor DarkGray
    }

    # Kill the 'tailscale up' process if still running
    if (-not $tsProcess.HasExited) {
        $tsProcess | Stop-Process -Force -ErrorAction SilentlyContinue
    }

    if (-not $authDone) {
        Write-Fail "Authentication timed out after $Timeout seconds."
        Write-Host "Run the script again, or authenticate manually with: tailscale up" -ForegroundColor Yellow
        exit 1
    }
}

# ---------------------------------------------------------------------------
# Step 4 — Verify and retrieve node information
# ---------------------------------------------------------------------------

Write-Step "Authentication complete — retrieving node information..."

# Allow a moment for state to settle
Start-Sleep -Seconds 2

$finalStatus = Get-TailscaleStatus -Exe $tsExe

if (-not (Test-TailscaleAuthenticated -StatusObj $finalStatus)) {
    Write-Fail "Unexpected state after auth: $($finalStatus.BackendState)"
    exit 1
}

$selfNode     = $finalStatus.Self
$nodeIP       = ($selfNode.TailscaleIPs | Where-Object { $_ -notmatch ":" } | Select-Object -First 1)
$nodeIPv6     = ($selfNode.TailscaleIPs | Where-Object { $_ -match ":" }    | Select-Object -First 1)
$nodeDns      = $selfNode.DNSName -replace "\.$", ""
$nodeHostname = $selfNode.HostName

# ---------------------------------------------------------------------------
# Step 5 — Apply server-mode flags explicitly (idempotent)
# ---------------------------------------------------------------------------

Write-Step "Configuring server-mode flags..."

$serverArgs = @(
    "up",
    "--accept-dns",
    "--shields-up=false",
    "--accept-routes"
)
if ($Hostname) { $serverArgs += "--hostname=$Hostname" }
if ($AuthKey)  { $serverArgs += "--authkey=$AuthKey" }

& $tsExe @serverArgs 2>&1 | Out-Null
Write-Success "Server-mode flags applied: accept-dns, shields-up=false, accept-routes."

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "======================================================" -ForegroundColor White
Write-Host " Tailscale Authentication Successful" -ForegroundColor Green
Write-Host "======================================================" -ForegroundColor White
Write-Host " Node hostname : $nodeHostname" -ForegroundColor White
Write-Host " Tailscale IP  : $nodeIP" -ForegroundColor White
if ($nodeIPv6) {
    Write-Host " Tailscale IPv6: $nodeIPv6" -ForegroundColor White
}
Write-Host " MagicDNS name : $nodeDns" -ForegroundColor White
Write-Host "======================================================" -ForegroundColor White
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. Run funnel-setup.ps1 to expose the web frontend publicly."
Write-Host "  2. Apply the ACL policy (acl-policy.hujson) in the Tailscale admin console."
Write-Host "  3. Assign the 'tag:remote-desktop' tag to this node."
Write-Host ""
