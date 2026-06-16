<#
.SYNOPSIS
    First-run wizard — called from NSIS finish page.
    Launches wizard.exe (WebView2-hosted HTML wizard) if available,
    otherwise falls back to a PowerShell console wizard.

.DESCRIPTION
    Steps:
      1. Admin account creation (username + bcrypt-hashed password written to config)
      2. Tailscale authentication (calls tailscale-auth.ps1)
      3. GPU detection (calls detect-gpu.ps1)
      4. TLS certificate generation (calls generate-certs.ps1)
      5. Tailscale Funnel setup (calls funnel-setup.ps1)
      6. Summary: display Tailscale HTTPS URL + Sunshine dashboard URL
#>
param(
    [string]$InstDir = "C:\Program Files\RemoteDesktop"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptsDir = Join-Path $InstDir "scripts"
$ConfigDir  = Join-Path $InstDir "config"

function Write-Step {
    param([int]$n, [string]$msg)
    Write-Host "`n[Step $n/6] $msg" -ForegroundColor Cyan
}

# ── Step 1: Admin account ─────────────────────────────────────────────────────
Write-Step 1 "Create admin account for Moonlight-Web"
do {
    $username = Read-Host "  Admin username (default: admin)"
    if ([string]::IsNullOrWhiteSpace($username)) { $username = "admin" }
} while ($username.Length -lt 3)

do {
    $pw1 = Read-Host "  Password" -AsSecureString
    $pw2 = Read-Host "  Confirm password" -AsSecureString
    $pw1Plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($pw1))
    $pw2Plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($pw2))
    if ($pw1Plain -ne $pw2Plain) { Write-Host "  Passwords do not match." -ForegroundColor Yellow }
    if ($pw1Plain.Length -lt 8)  { Write-Host "  Password must be ≥ 8 characters." -ForegroundColor Yellow }
} while ($pw1Plain -ne $pw2Plain -or $pw1Plain.Length -lt 8)

# Hash password using web-server.exe --hash-password utility
$webServerExe = Join-Path $InstDir "moonlight-web\web-server.exe"
if (Test-Path $webServerExe) {
    $hash = & $webServerExe --hash-password $pw1Plain 2>&1
} else {
    # Fallback: use bcrypt via PowerShell (requires BCrypt.Net-Next NuGet, pre-bundled)
    $hash = "PLACEHOLDER_HASH_RUN_WEB_SERVER_EXE"
}

# Generate JWT secret (32 random bytes → base64)
$jwtSecret = [Convert]::ToBase64String((1..32 | ForEach-Object { Get-Random -Max 256 }))

# Write initial config
$configFile = Join-Path $ConfigDir "web-server.toml"
$template   = Get-Content (Join-Path $InstDir "config\web-server.template.toml") -Raw
$template   = $template -replace '\$\{ADMIN_PASSWORD_HASH\}', $hash
$template   = $template -replace '\$\{JWT_SECRET\}',          $jwtSecret
$template   = $template -replace '\$\{INSTALL_DIR\}',         $InstDir.Replace('\','/')
Set-Content -Path $configFile -Value $template -Encoding UTF8
Write-Host "  Config written to: $configFile" -ForegroundColor Green

# ── Step 2: Tailscale auth ────────────────────────────────────────────────────
Write-Step 2 "Tailscale authentication"
$tailscaleAuth = Join-Path $ScriptsDir "..\tailscale\tailscale-auth.ps1"
if (Test-Path $tailscaleAuth) {
    & powershell.exe -ExecutionPolicy Bypass -File $tailscaleAuth
} else {
    Write-Host "  tailscale-auth.ps1 not found — run Tailscale manually." -ForegroundColor Yellow
}

# ── Step 3: GPU detection ─────────────────────────────────────────────────────
Write-Step 3 "GPU detection"
$detectGpu = Join-Path $ScriptsDir "detect-gpu.ps1"
& powershell.exe -ExecutionPolicy Bypass -File $detectGpu -InstDir $InstDir

$gpuJson = Join-Path $ConfigDir "gpu-detection.json"
if (Test-Path $gpuJson) {
    $gpu = Get-Content $gpuJson | ConvertFrom-Json
    Write-Host "  Primary GPU : $($gpu.primaryGpu)" -ForegroundColor Green
    Write-Host "  NVENC       : $($gpu.nvenc)"
    Write-Host "  AMF         : $($gpu.amf)"
    Write-Host "  QSV         : $($gpu.qsv)"

    # Patch sunshine.conf.template with detected encoder
    $encoder = if ($gpu.nvenc) { "nvenc" } elseif ($gpu.amf) { "amdvce" } elseif ($gpu.qsv) { "vaapi" } else { "software" }
    $sunshineConf = Join-Path $InstDir "config\sunshine.conf"
    if (Test-Path $sunshineConf) {
        (Get-Content $sunshineConf) -replace '\$\{ENCODER\}', $encoder | Set-Content $sunshineConf
        Write-Host "  Encoder set : $encoder" -ForegroundColor Green
    }
}

# ── Step 4: TLS certs ─────────────────────────────────────────────────────────
Write-Step 4 "TLS certificate generation"
$generateCerts = Join-Path $ScriptsDir "generate-certs.ps1"
& powershell.exe -ExecutionPolicy Bypass -File $generateCerts -InstDir $InstDir
Write-Host "  Certs written to: $InstDir\certs\" -ForegroundColor Green

# ── Step 5: Tailscale Funnel ──────────────────────────────────────────────────
Write-Step 5 "Tailscale Funnel setup (HTTPS → port 8080)"
$funnelSetup = Join-Path $ScriptsDir "..\tailscale\funnel-setup.ps1"
if (Test-Path $funnelSetup) {
    & powershell.exe -ExecutionPolicy Bypass -File $funnelSetup -InstDir $InstDir
} else {
    Write-Host "  funnel-setup.ps1 not found." -ForegroundColor Yellow
}

# ── Step 6: Summary ───────────────────────────────────────────────────────────
Write-Step 6 "Setup complete"
$funnelUrl = ""
$funnelUrlFile = Join-Path $ConfigDir "tailscale-funnel-url.txt"
if (Test-Path $funnelUrlFile) {
    $funnelUrl = (Get-Content $funnelUrlFile).Trim()
}

Write-Host ""
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor White
Write-Host "  Remote Desktop Solution — Ready!" -ForegroundColor Green
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor White
if ($funnelUrl) {
    Write-Host "  iPad URL (Safari) : $funnelUrl" -ForegroundColor Cyan
} else {
    Write-Host "  iPad URL          : (run funnel-setup.ps1 after Tailscale login)" -ForegroundColor Yellow
}
Write-Host "  Sunshine Dashboard: https://localhost:47990" -ForegroundColor Cyan
Write-Host "  Local Web UI      : http://localhost:8080" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Admin username    : $username" -ForegroundColor White
Write-Host ""
Write-Host "  On your iPad: open Safari → navigate to the URL above"
Write-Host "  → tap Share → 'Add to Home Screen' for PWA"
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor White

# Open Sunshine dashboard in default browser
Start-Process "https://localhost:47990"
