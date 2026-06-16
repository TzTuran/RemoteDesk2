#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Creates Windows Firewall rules for Remote Desktop Solution.

.PARAMETER InstDir
    The installation directory. Used to scope program-specific rules.
    Defaults to $env:PROGRAMFILES\RemoteDesktop for standalone use.

.NOTES
    Idempotent: existing rules with matching names are removed before recreation.
#>
[CmdletBinding()]
param(
    [string]$InstDir = "$env:PROGRAMFILES\RemoteDesktop"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    Write-Host "[configure-firewall] $Message" -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Message)
    Write-Host "[configure-firewall] OK: $Message" -ForegroundColor Green
}

function New-IdempotentFirewallRule {
    param(
        [string]  $DisplayName,
        [string]  $Description,
        [string]  $Protocol,
        [string]  $LocalPort,           # e.g. "47989,47990,48010" or "40000-40010"
        [string]  $Direction  = "Inbound",
        [string]  $Action     = "Allow",
        [string[]]$Profile    = @("Any"),
        [string]  $Program    = $null   # optional: full path to executable
    )

    # Remove any existing rule with this display name (idempotency)
    $existing = Get-NetFirewallRule -DisplayName $DisplayName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Step "Removing existing rule: $DisplayName"
        Remove-NetFirewallRule -DisplayName $DisplayName
    }

    Write-Step "Creating rule: $DisplayName ($Protocol $LocalPort)"

    $params = @{
        DisplayName = $DisplayName
        Description = $Description
        Protocol    = $Protocol
        LocalPort   = $LocalPort
        Direction   = $Direction
        Action      = $Action
        Profile     = $Profile
        Enabled     = "True"
    }

    if ($Program) {
        $params["Program"] = $Program
    }

    New-NetFirewallRule @params | Out-Null
    Write-Ok "Rule created: $DisplayName"
}

# ---------------------------------------------------------------------------
# Resolve paths for program-scoped rules
# ---------------------------------------------------------------------------
$SunshineExe    = Join-Path $InstDir "Sunshine\sunshine.exe"
$MoonlightWebExe = Join-Path $InstDir "moonlight-web\web-server.exe"

# Only scope rules to executables that exist; fall back to port-only rules
$SunshineProg   = if (Test-Path $SunshineExe)    { $SunshineExe }    else { $null }
$MoonlightProg  = if (Test-Path $MoonlightWebExe) { $MoonlightWebExe } else { $null }

# ---------------------------------------------------------------------------
# Rule 1: Sunshine HTTPS + HTTP + Control (TCP)
# ---------------------------------------------------------------------------
New-IdempotentFirewallRule `
    -DisplayName "RemoteDesktop-Sunshine-TCP" `
    -Description "Sunshine streaming host: HTTPS API (47990), HTTP redirect (47989), control channel (48010)" `
    -Protocol    "TCP" `
    -LocalPort   "47989,47990,48010" `
    -Profile     @("Any") `
    -Program     $SunshineProg

# ---------------------------------------------------------------------------
# Rule 2: Sunshine video/audio streams (UDP)
# ---------------------------------------------------------------------------
New-IdempotentFirewallRule `
    -DisplayName "RemoteDesktop-Sunshine-UDP" `
    -Description "Sunshine streaming host: video stream (47998), audio stream (47999)" `
    -Protocol    "UDP" `
    -LocalPort   "47998,47999" `
    -Profile     @("Any") `
    -Program     $SunshineProg

# ---------------------------------------------------------------------------
# Rule 3: WebRTC media (UDP range)
# ---------------------------------------------------------------------------
New-IdempotentFirewallRule `
    -DisplayName "RemoteDesktop-WebRTC-UDP" `
    -Description "WebRTC media relay ports for Moonlight Web P2P connections" `
    -Protocol    "UDP" `
    -LocalPort   "40000-40010" `
    -Profile     @("Any")

# ---------------------------------------------------------------------------
# Rule 4: Moonlight Web HTTP UI
# ---------------------------------------------------------------------------
New-IdempotentFirewallRule `
    -DisplayName "RemoteDesktop-MoonlightWeb-HTTP" `
    -Description "Moonlight Web client UI served on HTTP port 8080" `
    -Protocol    "TCP" `
    -LocalPort   "8080" `
    -Profile     @("Any") `
    -Program     $MoonlightProg

# ---------------------------------------------------------------------------
# Rule 5: Tailscale Funnel / general HTTPS
# ---------------------------------------------------------------------------
New-IdempotentFirewallRule `
    -DisplayName "RemoteDesktop-HTTPS" `
    -Description "HTTPS inbound for Tailscale Funnel and direct TLS access" `
    -Protocol    "TCP" `
    -LocalPort   "443" `
    -Profile     @("Any")

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "[configure-firewall] Firewall rules configured:" -ForegroundColor Green
$rules = Get-NetFirewallRule -DisplayName "RemoteDesktop-*" | Sort-Object DisplayName
foreach ($r in $rules) {
    $portFilter = $r | Get-NetFirewallPortFilter
    Write-Host ("  {0,-45} {1,4}  {2}" -f $r.DisplayName, $portFilter.Protocol, $portFilter.LocalPort) -ForegroundColor Gray
}
Write-Host ""
Write-Host "[configure-firewall] Done." -ForegroundColor Green
