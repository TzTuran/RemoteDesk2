#Requires -Version 5.1
<#
.SYNOPSIS
    Build script for Remote Desktop Solution installer.

.DESCRIPTION
    Downloads dependencies, builds Moonlight-Web frontend and Rust server,
    then compiles the NSIS installer and optionally code-signs the output.

.NOTES
    Set $env:SIGN_CERT to the certificate subject name to enable signing.
    Requires: makensis 3.x, Rust, Node.js 18+, 7-Zip on PATH.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Resolve script root so the script works from any working directory
# ---------------------------------------------------------------------------
$ScriptDir = $PSScriptRoot
if (-not $ScriptDir) { $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition }
Set-Location $ScriptDir

# ---------------------------------------------------------------------------
# Version
# ---------------------------------------------------------------------------
$VersionFile = Join-Path $ScriptDir "..\VERSION.txt"
if (-not (Test-Path $VersionFile)) {
    Write-Error "VERSION.txt not found at '$VersionFile'."
    exit 1
}
$VERSION = (Get-Content $VersionFile -Raw).Trim()
if ($VERSION -notmatch '^\d+\.\d+\.\d+') {
    Write-Error "VERSION.txt contents '$VERSION' do not match expected semver format."
    exit 1
}
Write-Host "Building version: $VERSION" -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Assert-Command {
    param([string]$Name, [string]$Hint = "")
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        $msg = "Required tool '$Name' not found on PATH."
        if ($Hint) { $msg += " $Hint" }
        Write-Error $msg
        exit 1
    }
    Write-Host "  [OK] $Name" -ForegroundColor Green
}

function Invoke-StepHeader {
    param([string]$Title)
    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor DarkCyan
    Write-Host "  STEP: $Title" -ForegroundColor Cyan
    Write-Host ("=" * 70) -ForegroundColor DarkCyan
}

function Get-Sha256 {
    param([string]$FilePath)
    $hash = Get-FileHash -Path $FilePath -Algorithm SHA256
    return $hash.Hash
}

function Invoke-Download {
    param(
        [string]$Uri,
        [string]$OutFile,
        [string]$Description
    )
    Write-Host "  Downloading $Description..."
    Write-Host "    URL : $Uri"
    Write-Host "    Dest: $OutFile"
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing
    $ProgressPreference = 'Continue'
    if (-not (Test-Path $OutFile)) {
        Write-Error "Download failed: '$OutFile' was not created."
        exit 1
    }
    $size = (Get-Item $OutFile).Length
    Write-Host "    Size: $([math]::Round($size/1MB,2)) MB" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Step 1: Prerequisite checks
# ---------------------------------------------------------------------------
Invoke-StepHeader "Checking prerequisites"

# NSIS 3.x
Assert-Command "makensis" "Install from https://nsis.sourceforge.io/"
$nsisVersion = (makensis /VERSION 2>&1) -join ""
if ($nsisVersion -notmatch '^v3\.') {
    Write-Error "NSIS 3.x required; found: $nsisVersion"
    exit 1
}
Write-Host "  NSIS version: $nsisVersion" -ForegroundColor Green

# Rust toolchain
Assert-Command "cargo" "Install from https://rustup.rs/"
$rustVersion = (cargo --version 2>&1) -join ""
Write-Host "  Rust: $rustVersion" -ForegroundColor Green

# Node.js 18+
Assert-Command "node" "Install Node.js 18+ from https://nodejs.org/"
$nodeVersion = [Version]((node --version) -replace 'v','')
if ($nodeVersion.Major -lt 18) {
    Write-Error "Node.js 18+ required; found v$nodeVersion"
    exit 1
}
Write-Host "  Node.js: v$nodeVersion" -ForegroundColor Green

Assert-Command "npm"  "Comes with Node.js"

# 7-Zip (optional but common; used for extraction if needed)
$sevenZipPath = $null
foreach ($p in @("7z", "7za")) {
    if (Get-Command $p -ErrorAction SilentlyContinue) {
        $sevenZipPath = $p
        Write-Host "  [OK] 7-Zip ($p)" -ForegroundColor Green
        break
    }
}
if (-not $sevenZipPath) {
    Write-Warning "7-Zip not found; some extraction steps may be skipped."
}

# signtool (only required when $env:SIGN_CERT is set)
if ($env:SIGN_CERT) {
    Assert-Command "signtool" "Install Windows SDK"
}

# ---------------------------------------------------------------------------
# Step 2: Ensure resources directory exists
# ---------------------------------------------------------------------------
$ResourcesDir = Join-Path $ScriptDir "resources"
New-Item -ItemType Directory -Force -Path $ResourcesDir | Out-Null

# ---------------------------------------------------------------------------
# Step 3: Download Sunshine
# ---------------------------------------------------------------------------
Invoke-StepHeader "Downloading Sunshine"

$SunshineInstallerPath = Join-Path $ResourcesDir "sunshine-installer.exe"
try {
    $ProgressPreference = 'SilentlyContinue'
    $ReleaseMeta = Invoke-RestMethod `
        -Uri "https://api.github.com/repos/LizardByte/Sunshine/releases/latest" `
        -Headers @{ "User-Agent" = "RemoteDesktopSolutionBuildScript/1.0" } `
        -UseBasicParsing
    $ProgressPreference = 'Continue'
}
catch {
    Write-Error "Failed to query GitHub API for Sunshine release: $_"
    exit 1
}

$SunshineAsset = $ReleaseMeta.assets |
    Where-Object { $_.name -match 'windows.*installer.*\.exe$|sunshine.*windows.*\.exe$' -and $_.name -notmatch 'portable' } |
    Sort-Object created_at -Descending |
    Select-Object -First 1

if (-not $SunshineAsset) {
    # Fallback: take the first .exe asset
    $SunshineAsset = $ReleaseMeta.assets |
        Where-Object { $_.name -match '\.exe$' } |
        Select-Object -First 1
}

if (-not $SunshineAsset) {
    Write-Error "Could not find a suitable Sunshine installer asset in the latest release."
    exit 1
}

Write-Host "  Found Sunshine asset: $($SunshineAsset.name)"
Invoke-Download -Uri $SunshineAsset.browser_download_url `
                -OutFile $SunshineInstallerPath `
                -Description "Sunshine installer ($($ReleaseMeta.tag_name))"

# ---------------------------------------------------------------------------
# Step 4: Download Tailscale MSI
# ---------------------------------------------------------------------------
Invoke-StepHeader "Downloading Tailscale"

$TailscaleMsiPath = Join-Path $ResourcesDir "tailscale.msi"
Invoke-Download `
    -Uri    "https://pkgs.tailscale.com/stable/tailscale-setup-latest-amd64.msi" `
    -OutFile $TailscaleMsiPath `
    -Description "Tailscale Windows MSI"

# ---------------------------------------------------------------------------
# Step 5: Build Moonlight-Web frontend
# ---------------------------------------------------------------------------
Invoke-StepHeader "Building Moonlight-Web frontend"

$WebDir = Resolve-Path (Join-Path $ScriptDir "..\moonlight-web\web")
Write-Host "  Working directory: $WebDir"
Push-Location $WebDir
try {
    Write-Host "  Running npm ci..."
    & npm ci
    if ($LASTEXITCODE -ne 0) { throw "npm ci failed with exit code $LASTEXITCODE" }

    Write-Host "  Running npm run build..."
    & npm run build
    if ($LASTEXITCODE -ne 0) { throw "npm run build failed with exit code $LASTEXITCODE" }
}
finally {
    Pop-Location
}

# ---------------------------------------------------------------------------
# Step 6: Build Rust web server
# ---------------------------------------------------------------------------
Invoke-StepHeader "Building Rust web server"

$ServerDir = Resolve-Path (Join-Path $ScriptDir "..\moonlight-web\server")
Write-Host "  Working directory: $ServerDir"
Push-Location $ServerDir
try {
    Write-Host "  Running cargo build --release..."
    & cargo build --release
    if ($LASTEXITCODE -ne 0) { throw "cargo build failed with exit code $LASTEXITCODE" }
}
finally {
    Pop-Location
}

$RustExeSrc = Join-Path $ServerDir "target\release\web-server.exe"
$RustExeDst = Join-Path $ResourcesDir "web-server.exe"
if (-not (Test-Path $RustExeSrc)) {
    Write-Error "Rust build succeeded but output binary not found at '$RustExeSrc'."
    exit 1
}
Copy-Item -Force $RustExeSrc $RustExeDst
Write-Host "  Copied web-server.exe to resources." -ForegroundColor Green

# ---------------------------------------------------------------------------
# Step 7: Copy static assets
# ---------------------------------------------------------------------------
Invoke-StepHeader "Copying static assets"

$StaticSrc = Join-Path $ServerDir "static"
$StaticDst = Join-Path $ResourcesDir "static"
New-Item -ItemType Directory -Force -Path $StaticDst | Out-Null

$robocopyResult = & robocopy $StaticSrc $StaticDst /E /NFL /NDL /NJH /NJS
# robocopy exit codes < 8 indicate success
if ($LASTEXITCODE -ge 8) {
    Write-Error "robocopy failed copying static assets (exit code $LASTEXITCODE)."
    exit 1
}
Write-Host "  Static assets copied." -ForegroundColor Green

# ---------------------------------------------------------------------------
# Step 8: Copy config templates
# ---------------------------------------------------------------------------
Invoke-StepHeader "Copying config templates"

$ConfigDst = Join-Path $ResourcesDir "config"
New-Item -ItemType Directory -Force -Path $ConfigDst | Out-Null

# Sunshine config
$SunshineConfigSrc = Join-Path $ScriptDir "..\sunshine-config"
if (Test-Path $SunshineConfigSrc) {
    $r = & robocopy $SunshineConfigSrc $ConfigDst /E /NFL /NDL /NJH /NJS
    if ($LASTEXITCODE -ge 8) {
        Write-Error "robocopy failed copying sunshine config (exit code $LASTEXITCODE)."
        exit 1
    }
    Write-Host "  Sunshine config templates copied." -ForegroundColor Green
}
else {
    Write-Warning "sunshine-config directory not found at '$SunshineConfigSrc'; skipping."
}

# Tailscale ACL templates
$TailscaleConfigSrc = Join-Path $ScriptDir "..\tailscale-config"
if (Test-Path $TailscaleConfigSrc) {
    $r = & robocopy $TailscaleConfigSrc $ConfigDst /E /NFL /NDL /NJH /NJS
    if ($LASTEXITCODE -ge 8) {
        Write-Error "robocopy failed copying tailscale config (exit code $LASTEXITCODE)."
        exit 1
    }
    Write-Host "  Tailscale config templates copied." -ForegroundColor Green
}

# coturn Docker Compose
$CoturnSrc = Join-Path $ScriptDir "..\coturn"
$CoturnDst = Join-Path $ResourcesDir "coturn"
if (Test-Path $CoturnSrc) {
    New-Item -ItemType Directory -Force -Path $CoturnDst | Out-Null
    $r = & robocopy $CoturnSrc $CoturnDst /E /NFL /NDL /NJH /NJS
    if ($LASTEXITCODE -ge 8) {
        Write-Error "robocopy failed copying coturn assets (exit code $LASTEXITCODE)."
        exit 1
    }
    Write-Host "  coturn assets copied." -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Step 9: Compile NSIS installer
# ---------------------------------------------------------------------------
Invoke-StepHeader "Compiling NSIS installer"

$OutExe = Join-Path $ScriptDir "RemoteDesktop-Host-Setup-$VERSION.exe"
$NsiFile = Join-Path $ScriptDir "installer.nsi"

Write-Host "  Running: makensis /DVERSION=$VERSION installer.nsi"
& makensis /DVERSION=$VERSION $NsiFile
if ($LASTEXITCODE -ne 0) {
    Write-Error "makensis failed with exit code $LASTEXITCODE."
    exit 1
}

if (-not (Test-Path $OutExe)) {
    Write-Error "NSIS compilation succeeded but output file '$OutExe' not found."
    exit 1
}

Write-Host "  Installer compiled: $OutExe" -ForegroundColor Green

# ---------------------------------------------------------------------------
# Step 10: Code-sign (optional)
# ---------------------------------------------------------------------------
if ($env:SIGN_CERT) {
    Invoke-StepHeader "Code-signing installer"
    Write-Host "  Certificate subject: $env:SIGN_CERT"
    & signtool.exe sign `
        /tr  "http://timestamp.digicert.com" `
        /td  sha256 `
        /fd  sha256 `
        /n   "$env:SIGN_CERT" `
        $OutExe
    if ($LASTEXITCODE -ne 0) {
        Write-Error "signtool failed with exit code $LASTEXITCODE."
        exit 1
    }
    Write-Host "  Signed successfully." -ForegroundColor Green
}
else {
    Write-Warning "SIGN_CERT environment variable not set; skipping code signing."
}

# ---------------------------------------------------------------------------
# Step 11: Print SHA-256 hash
# ---------------------------------------------------------------------------
Invoke-StepHeader "Output summary"

$Hash = Get-Sha256 -FilePath $OutExe
$SizeBytes = (Get-Item $OutExe).Length
$SizeMB = [math]::Round($SizeBytes / 1MB, 2)

Write-Host ""
Write-Host "  Output   : $OutExe"
Write-Host "  Version  : $VERSION"
Write-Host "  Size     : $SizeMB MB ($SizeBytes bytes)"
Write-Host "  SHA-256  : $Hash"
Write-Host ""
Write-Host "Build completed successfully." -ForegroundColor Green
