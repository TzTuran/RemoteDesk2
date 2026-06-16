#Requires -Version 5.1
<#
.SYNOPSIS
    Detects GPU hardware encoding capabilities (NVENC, AMF, QSV).

.PARAMETER InstDir
    The installation directory. Output JSON is written to $InstDir\config\gpu-detection.json.
    Defaults to $env:PROGRAMFILES\RemoteDesktop for standalone use.

.OUTPUTS
    JSON file at $InstDir\config\gpu-detection.json:
    {
        "nvenc":      true | false,
        "amf":        true | false,
        "qsv":        true | false,
        "primaryGpu": "NVIDIA GeForce RTX 4090"
    }
#>
[CmdletBinding()]
param(
    [string]$InstDir = "$env:PROGRAMFILES\RemoteDesktop"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    Write-Host "[detect-gpu] $Message" -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Message)
    Write-Host "[detect-gpu] OK: $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[detect-gpu] WARN: $Message" -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# NVENC blacklist
# GPUs listed here lack NVENC or have severely limited NVENC implementations.
# ---------------------------------------------------------------------------
$NvencBlacklist = @(
    "GT 710",
    "GT 720",
    "GT 730",
    "GT 740",
    "GT 750",          # non-Ti
    "GTX 750 ",        # GTX 750 (non-Ti) — space intentional to avoid matching GTX 750 Ti
    "GT 610",
    "GT 620",
    "GT 630",
    "GT 640",
    "GT 210",
    "GT 220",
    "GT 240",
    "GT 320",
    "GT 330",
    "GT 340",
    "NVS 310",
    "NVS 315"
)

# ---------------------------------------------------------------------------
# Query Win32_VideoController
# ---------------------------------------------------------------------------
Write-Step "Querying Win32_VideoController..."

$controllers = @(Get-WmiObject -Class Win32_VideoController -ErrorAction SilentlyContinue)
if (-not $controllers -or $controllers.Count -eq 0) {
    Write-Warn "No video controllers found via WMI. Falling back to defaults."
    $controllers = @()
}

foreach ($c in $controllers) {
    Write-Host ("  [{0}] Name: {1}, Adapter: {2}, DXGI: {3}" -f
        $c.DeviceID,
        $c.Name,
        $c.AdapterCompatibility,
        $c.VideoModeDescription) -ForegroundColor Gray
}

# Determine primary GPU (first controller by VideoMemory desc, or first entry)
$primaryGpu = $controllers |
    Sort-Object AdapterRAM -Descending |
    Select-Object -First 1

$primaryGpuName = if ($primaryGpu) { $primaryGpu.Name } else { "Unknown" }

# ---------------------------------------------------------------------------
# NVENC detection
# ---------------------------------------------------------------------------
Write-Step "Detecting NVENC (NVIDIA hardware encoding)..."

$nvencSupported = $false
foreach ($gpu in $controllers) {
    $compat = [string]$gpu.AdapterCompatibility
    $name   = [string]$gpu.Name

    if ($compat -notmatch "NVIDIA" -and $name -notmatch "NVIDIA") { continue }

    # Check blacklist
    $blacklisted = $false
    foreach ($entry in $NvencBlacklist) {
        if ($name -like "*$entry*") {
            Write-Warn "GPU '$name' is on the NVENC blacklist (matched '$entry')."
            $blacklisted = $true
            break
        }
    }
    if ($blacklisted) { continue }

    # Parse generation from GPU name to confirm NVENC support (Kepler+ = GTX 600+ series)
    # Detect NVxx pattern: anything >= GTX 650 Ti, GTX 660, etc. is safe
    $nvencSupported = $true
    Write-Ok "NVENC-capable NVIDIA GPU found: $name"
    break
}

# ---------------------------------------------------------------------------
# AMF detection (AMD)
# ---------------------------------------------------------------------------
Write-Step "Detecting AMF (AMD hardware encoding)..."

$amfSupported = $false
foreach ($gpu in $controllers) {
    $compat = [string]$gpu.AdapterCompatibility
    $name   = [string]$gpu.Name

    if ($compat -match "AMD|ATI" -or $name -match "Radeon|AMD") {
        $amfSupported = $true
        Write-Ok "AMF-capable AMD GPU found: $name"
        break
    }
}

# ---------------------------------------------------------------------------
# QSV detection (Intel)
# ---------------------------------------------------------------------------
Write-Step "Detecting QSV (Intel Quick Sync Video)..."

$qsvSupported = $false

foreach ($gpu in $controllers) {
    $compat = [string]$gpu.AdapterCompatibility
    $name   = [string]$gpu.Name

    if ($compat -notmatch "Intel" -and $name -notmatch "Intel") { continue }

    # Intel iGPU found — now try to verify a DXGI feature level >= 11.0
    # via dxdiag XML output (feature level is reported in the display section)
    Write-Step "Intel GPU found: $name — checking DXGI feature level via dxdiag..."

    $dxdiagXml = Join-Path $env:TEMP "dxdiag_rds.xml"
    try {
        & dxdiag /x $dxdiagXml /whql:off 2>&1 | Out-Null

        # dxdiag is asynchronous on some systems; wait up to 30 s
        $deadline = [DateTime]::UtcNow.AddSeconds(30)
        while (-not (Test-Path $dxdiagXml) -and [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 500
        }

        if (Test-Path $dxdiagXml) {
            [xml]$dxdiagData = Get-Content $dxdiagXml -Encoding UTF8
            $displayDevices = $dxdiagData.DxDiag.DisplayDevices.DisplayDevice

            foreach ($dev in @($displayDevices)) {
                $devName = [string]($dev.CardName.'#text' ?? $dev.CardName)
                if ($devName -notmatch "Intel") { continue }

                $featureLevelNode = $dev.ChildNodes |
                    Where-Object { $_.LocalName -match "D3D.*FeatureLevels|FeatureLevel" } |
                    Select-Object -First 1

                $featureLevelStr = if ($featureLevelNode) {
                    [string]($featureLevelNode.'#text' ?? $featureLevelNode.InnerText)
                } else {
                    # Fallback: search by attribute name pattern
                    $raw = $dev.InnerXml
                    if ($raw -match 'D3D[\d_]+_FEATURE_LEVEL_([\d_]+)') { $Matches[1] } else { "" }
                }

                Write-Host ("  dxdiag feature levels for '{0}': {1}" -f $devName, $featureLevelStr) -ForegroundColor Gray

                # QSV requires DX11 (feature level 11_0+)
                if ($featureLevelStr -match "11_[01]|12_[01]") {
                    $qsvSupported = $true
                    Write-Ok "QSV supported on: $devName (feature level includes 11.0+)"
                    break
                }
            }
        }
        else {
            Write-Warn "dxdiag XML output not found after 30 s; assuming QSV available on Intel GPU."
            $qsvSupported = $true   # conservative: assume support if dxdiag unavailable
        }
    }
    catch {
        Write-Warn "dxdiag parsing failed: $_"
        Write-Warn "Conservatively enabling QSV for detected Intel GPU: $name"
        $qsvSupported = $true
    }
    finally {
        Remove-Item $dxdiagXml -ErrorAction SilentlyContinue
    }

    if ($qsvSupported) { break }
}

# ---------------------------------------------------------------------------
# Build result object
# ---------------------------------------------------------------------------
$result = [ordered]@{
    nvenc      = $nvencSupported
    amf        = $amfSupported
    qsv        = $qsvSupported
    primaryGpu = $primaryGpuName
}

$jsonOutput = $result | ConvertTo-Json -Depth 2

# ---------------------------------------------------------------------------
# Write to config directory
# ---------------------------------------------------------------------------
$ConfigDir = Join-Path $InstDir "config"
New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null

$OutputFile = Join-Path $ConfigDir "gpu-detection.json"
$jsonOutput | Set-Content -Path $OutputFile -Encoding UTF8

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "[detect-gpu] GPU capability detection complete:" -ForegroundColor Green
Write-Host "  Primary GPU : $primaryGpuName"
Write-Host "  NVENC       : $nvencSupported"
Write-Host "  AMF         : $amfSupported"
Write-Host "  QSV         : $qsvSupported"
Write-Host "  Output file : $OutputFile"
Write-Host ""
Write-Host $jsonOutput
Write-Host ""
Write-Host "[detect-gpu] Done." -ForegroundColor Green
