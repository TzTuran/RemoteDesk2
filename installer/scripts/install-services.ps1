#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs and starts all Windows services for Remote Desktop Solution.

.PARAMETER InstDir
    The installation directory (passed from the NSIS installer).
    Defaults to $env:PROGRAMFILES\RemoteDesktop for standalone use.
#>
[CmdletBinding()]
param(
    [string]$InstDir = "$env:PROGRAMFILES\RemoteDesktop"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Write-Step {
    param([string]$Message)
    Write-Host "[install-services] $Message" -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Message)
    Write-Host "[install-services] OK: $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[install-services] WARN: $Message" -ForegroundColor Yellow
}

function Wait-ServiceRunning {
    param(
        [string]$Name,
        [int]   $TimeoutSeconds = 30
    )
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') { return $true }
        Start-Sleep -Milliseconds 500
    }
    throw "Service '$Name' did not reach Running state within $TimeoutSeconds seconds."
}

function Set-ServiceFailureActions {
    param([string]$Name)
    # Configure: restart after 1st failure (60 s), restart after 2nd (60 s),
    # restart after 3rd+ (300 s); reset failure count after 24 h
    & sc.exe failure $Name reset= 86400 actions= restart/60000/restart/60000/restart/300000 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "Could not set failure actions for service '$Name' (exit code $LASTEXITCODE)."
    }
}

# ---------------------------------------------------------------------------
# Validate install directory
# ---------------------------------------------------------------------------
if (-not (Test-Path $InstDir)) {
    throw "Installation directory '$InstDir' does not exist."
}

# Ensure logs directory
$LogsDir = Join-Path $InstDir "logs"
New-Item -ItemType Directory -Force -Path $LogsDir | Out-Null
Write-Ok "Logs directory: $LogsDir"

# ---------------------------------------------------------------------------
# 1. MoonlightWebServer service
# ---------------------------------------------------------------------------
Write-Step "Installing MoonlightWebServer service..."

$MWS_BinPath = Join-Path $InstDir "moonlight-web\web-server.exe"
$MWS_Config  = Join-Path $InstDir "config\web-server.toml"

if (-not (Test-Path $MWS_BinPath)) {
    throw "web-server.exe not found at '$MWS_BinPath'."
}

$existingMWS = Get-Service -Name "MoonlightWebServer" -ErrorAction SilentlyContinue
if ($existingMWS) {
    Write-Warn "MoonlightWebServer service already exists; stopping and recreating."
    if ($existingMWS.Status -eq 'Running') {
        Stop-Service -Name "MoonlightWebServer" -Force
    }
    & sc.exe delete "MoonlightWebServer" | Out-Null
    Start-Sleep -Seconds 2
}

New-Service `
    -Name        "MoonlightWebServer" `
    -BinaryPathName "`"$MWS_BinPath`" --config `"$MWS_Config`"" `
    -DisplayName "Moonlight Web Server" `
    -StartupType Automatic `
    -Description "Serves the Moonlight Web client on port 8080" | Out-Null

Write-Ok "MoonlightWebServer service created."
Set-ServiceFailureActions -Name "MoonlightWebServer"

# ---------------------------------------------------------------------------
# 2. Verify SunshineService (installed by Sunshine's own installer)
# ---------------------------------------------------------------------------
Write-Step "Verifying SunshineService..."

$sunshineRetries = 10
$sunshineFound   = $false
for ($i = 0; $i -lt $sunshineRetries; $i++) {
    $svc = Get-Service -Name "SunshineService" -ErrorAction SilentlyContinue
    if ($svc) {
        $sunshineFound = $true
        Write-Ok "SunshineService found (status: $($svc.Status))."
        break
    }
    Write-Warn "SunshineService not yet registered; waiting... ($($i+1)/$sunshineRetries)"
    Start-Sleep -Seconds 3
}

if (-not $sunshineFound) {
    throw "SunshineService was not found after waiting. Ensure Sunshine installed successfully."
}

# Ensure Sunshine is set to Automatic start
Set-Service -Name "SunshineService" -StartupType Automatic
Set-ServiceFailureActions -Name "SunshineService"

# ---------------------------------------------------------------------------
# 3. Tailscale service
# ---------------------------------------------------------------------------
Write-Step "Installing/verifying Tailscale service..."

$tailscaleExe = $null
# Search common install locations
$candidatePaths = @(
    "$env:ProgramFiles\Tailscale\tailscale.exe",
    "$env:ProgramFiles(x86)\Tailscale\tailscale.exe",
    (Get-Command "tailscale.exe" -ErrorAction SilentlyContinue)?.Source
)
foreach ($c in $candidatePaths) {
    if ($c -and (Test-Path $c)) {
        $tailscaleExe = $c
        break
    }
}

$existingTailscale = Get-Service -Name "Tailscale" -ErrorAction SilentlyContinue
if ($existingTailscale) {
    Write-Ok "Tailscale service already registered (status: $($existingTailscale.Status))."
    Set-Service -Name "Tailscale" -StartupType Automatic
}
elseif ($tailscaleExe) {
    Write-Step "Registering Tailscale service via tailscale.exe /installservice..."
    & $tailscaleExe /installservice
    if ($LASTEXITCODE -ne 0) {
        throw "tailscale.exe /installservice failed with exit code $LASTEXITCODE."
    }
    Start-Sleep -Seconds 2
    $ts = Get-Service -Name "Tailscale" -ErrorAction SilentlyContinue
    if (-not $ts) {
        throw "Tailscale service was not found after /installservice."
    }
    Set-Service -Name "Tailscale" -StartupType Automatic
    Write-Ok "Tailscale service registered."
    Set-ServiceFailureActions -Name "Tailscale"
}
else {
    Write-Warn "tailscale.exe not found; skipping Tailscale service registration."
}

# ---------------------------------------------------------------------------
# 4. Start all services
# ---------------------------------------------------------------------------
$ServicesToStart = @(
    @{ Name = "Tailscale";         Optional = $true  }
    @{ Name = "SunshineService";   Optional = $false }
    @{ Name = "MoonlightWebServer"; Optional = $false }
)

foreach ($entry in $ServicesToStart) {
    $svcName = $entry.Name
    $isOpt   = $entry.Optional

    $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
    if (-not $svc) {
        if ($isOpt) {
            Write-Warn "$svcName not found; skipping start."
            continue
        }
        else {
            throw "Required service '$svcName' not found."
        }
    }

    if ($svc.Status -eq 'Running') {
        Write-Ok "$svcName is already running."
        continue
    }

    Write-Step "Starting $svcName..."
    Start-Service -Name $svcName

    try {
        Wait-ServiceRunning -Name $svcName -TimeoutSeconds 30
        Write-Ok "$svcName started successfully."
    }
    catch {
        if ($isOpt) {
            Write-Warn "$svcName failed to start: $_"
        }
        else {
            throw $_
        }
    }
}

Write-Host ""
Write-Host "[install-services] All services configured and started." -ForegroundColor Green
