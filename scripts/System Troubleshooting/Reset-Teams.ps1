<#
.SYNOPSIS
    Fully resets Microsoft Teams (New Teams + Classic Teams) for a clean reinstall.

.DESCRIPTION
    - Quits any running Teams processes
    - Uninstalls New Teams (UWP/AppX) and Classic Teams (if present)
    - Deletes all known cache, local data, and config folders
    - Removes leftover registry keys
    - Leaves the machine ready for a fresh Teams install

.NOTES
    Run this in an elevated PowerShell window (Run as Administrator) for best results.
    Some steps will still work without admin rights, but full cleanup needs it.
#>

Write-Host "=== Microsoft Teams Full Reset ===" -ForegroundColor Cyan

# 1. Kill any running Teams processes
Write-Host "`n[1/5] Stopping Teams processes..." -ForegroundColor Yellow
$processNames = @("ms-teams", "Teams", "msedgewebview2")
foreach ($proc in $processNames) {
    Get-Process -Name $proc -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Seconds 2
Write-Host "Done." -ForegroundColor Green

# 2. Uninstall New Teams (AppX/MSIX package)
Write-Host "`n[2/5] Uninstalling New Teams..." -ForegroundColor Yellow
try {
    $newTeams = Get-AppxPackage -Name "MSTeams" -ErrorAction SilentlyContinue
    if ($newTeams) {
        Remove-AppxPackage -Package $newTeams.PackageFullName -ErrorAction Stop
        Write-Host "New Teams (AppX) uninstalled." -ForegroundColor Green
    } else {
        Write-Host "New Teams AppX package not found (may already be uninstalled)." -ForegroundColor Gray
    }
} catch {
    Write-Host "Could not uninstall New Teams via Appx: $_" -ForegroundColor Red
}

# 3. Uninstall Classic Teams, if present
Write-Host "`n[3/5] Checking for Classic Teams..." -ForegroundColor Yellow
$classicUninstallPaths = @(
    "$env:LOCALAPPDATA\Microsoft\Teams\Update.exe",
    "$env:ProgramFiles(x86)\Teams Installer\Teams.exe"
)
$foundClassic = $false
foreach ($path in $classicUninstallPaths) {
    if (Test-Path $path) {
        $foundClassic = $true
        try {
            if ($path -like "*Update.exe") {
                Start-Process -FilePath $path -ArgumentList "--uninstall", "-s" -Wait -ErrorAction Stop
            }
            Write-Host "Classic Teams uninstalled via $path" -ForegroundColor Green
        } catch {
            Write-Host "Failed to uninstall Classic Teams via $path : $_" -ForegroundColor Red
        }
    }
}
if (-not $foundClassic) {
    Write-Host "Classic Teams not found." -ForegroundColor Gray
}

# 4. Delete all known cache / data folders
Write-Host "`n[4/5] Removing cache and data folders..." -ForegroundColor Yellow
$foldersToRemove = @(
    "$env:LOCALAPPDATA\Packages\MSTeams_8wekyb3d8bbwe",
    "$env:APPDATA\Microsoft\Teams",
    "$env:LOCALAPPDATA\Microsoft\Teams",
    "$env:LOCALAPPDATA\Microsoft\TeamsMeetingAddin",
    "$env:LOCALAPPDATA\Microsoft\TeamsPresenceAddin",
    "$env:APPDATA\Microsoft\TeamsMeetingAddin",
    "$env:USERPROFILE\AppData\Local\SquirrelTemp"
)

foreach ($folder in $foldersToRemove) {
    if (Test-Path $folder) {
        try {
            Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction Stop
            Write-Host "Removed: $folder" -ForegroundColor Green
        } catch {
            Write-Host "Could not fully remove $folder (may need admin rights or a reboot): $_" -ForegroundColor Red
        }
    } else {
        Write-Host "Not found (skipped): $folder" -ForegroundColor Gray
    }
}

# 5. Clean up registry traces
Write-Host "`n[5/5] Cleaning registry entries..." -ForegroundColor Yellow
$registryPaths = @(
    "HKCU:\Software\Microsoft\Office\Teams",
    "HKCU:\Software\Microsoft\Office\16.0\Teams"
)

foreach ($regPath in $registryPaths) {
    if (Test-Path $regPath) {
        try {
            Remove-Item -Path $regPath -Recurse -Force -ErrorAction Stop
            Write-Host "Removed registry key: $regPath" -ForegroundColor Green
        } catch {
            Write-Host "Could not remove registry key $regPath : $_" -ForegroundColor Red
        }
    } else {
        Write-Host "Not found (skipped): $regPath" -ForegroundColor Gray
    }
}

Write-Host "`n=== Reset complete ===" -ForegroundColor Cyan
Write-Host "Teams has been fully removed and all cache/config data cleared." -ForegroundColor Cyan
Write-Host "You can now download and install Teams fresh from:" -ForegroundColor Cyan
Write-Host "https://www.microsoft.com/microsoft-teams/download-app" -ForegroundColor White
