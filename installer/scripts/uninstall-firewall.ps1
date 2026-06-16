#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Removes all Windows Firewall rules created by Remote Desktop Solution.

.DESCRIPTION
    Deletes every rule whose DisplayName starts with "RemoteDesktop-".
    Safe to run even if rules were partially or not yet created.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    Write-Host "[uninstall-firewall] $Message" -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Message)
    Write-Host "[uninstall-firewall] OK: $Message" -ForegroundColor Green
}

Write-Step "Searching for RemoteDesktop-* firewall rules..."

# Get all matching rules before attempting removal (avoids mid-loop collection mutation)
$rules = Get-NetFirewallRule -DisplayName "RemoteDesktop-*" -ErrorAction SilentlyContinue

if (-not $rules -or @($rules).Count -eq 0) {
    Write-Ok "No RemoteDesktop-* firewall rules found. Nothing to remove."
    exit 0
}

$count = @($rules).Count
Write-Step "Found $count rule(s) to remove:"
foreach ($r in $rules) {
    Write-Host ("  - {0}" -f $r.DisplayName) -ForegroundColor Gray
}

Write-Step "Removing rules..."
Remove-NetFirewallRule -DisplayName "RemoteDesktop-*"

# Verify removal
$remaining = Get-NetFirewallRule -DisplayName "RemoteDesktop-*" -ErrorAction SilentlyContinue
if ($remaining -and @($remaining).Count -gt 0) {
    Write-Host "[uninstall-firewall] WARNING: $(@($remaining).Count) rule(s) could not be removed:" -ForegroundColor Yellow
    foreach ($r in $remaining) {
        Write-Host "  - $($r.DisplayName)" -ForegroundColor Yellow
    }
    exit 1
}

Write-Ok "All $count RemoteDesktop-* firewall rule(s) removed successfully."
Write-Host ""
Write-Host "[uninstall-firewall] Done." -ForegroundColor Green
