# Windows 11 Update & Temporary Files Cleanup Script
# Purpose: Clean up Windows updates and temp files to resolve boot hangs
# Requires: Administrator privileges
# =====================================================

# Check for admin privileges
if (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Host "ERROR: This script requires Administrator privileges!" -ForegroundColor Red
    Write-Host "Please run PowerShell as Administrator and try again." -ForegroundColor Yellow
    exit 1
}

Write-Host "======================================================" -ForegroundColor Cyan
Write-Host "  Windows 11 Update & Temp Files Cleanup Tool" -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host ""

# Variables
$TempPath = "$env:WINDIR\Temp"
$UserTemp = "$env:USERPROFILE\AppData\Local\Temp"
$UpdatePath = "$env:WINDIR\SoftwareDistribution\Download"
$LogPath = "$env:WINDIR\Logs\CBS"
$PrefetchPath = "$env:WINDIR\Prefetch"

# Function to get folder size in MB
function Get-FolderSizeMB {
    param([string]$Path)

    if (Test-Path $Path) {
        $Size = (Get-ChildItem -Path $Path -Recurse -Force -ErrorAction SilentlyContinue |
                 Measure-Object -Property Length -Sum).Sum
        if ($Size) {
            return [math]::Round($Size / 1MB, 2)
        }
    }
    return 0
}

# Display current sizes
Write-Host "CURRENT FOLDER SIZES:" -ForegroundColor Yellow
Write-Host "------------------------------------------------------"
$size1 = Get-FolderSizeMB $TempPath
$size2 = Get-FolderSizeMB $UserTemp
$size3 = Get-FolderSizeMB $UpdatePath
$size4 = Get-FolderSizeMB $PrefetchPath

Write-Host ("  Windows Temp ({0}): {1} MB" -f $TempPath, $size1)
Write-Host ("  User Temp ({0}): {1} MB" -f $UserTemp, $size2)
Write-Host ("  Windows Update Cache ({0}): {1} MB" -f $UpdatePath, $size3)
Write-Host ("  Prefetch ({0}): {1} MB" -f $PrefetchPath, $size4)
Write-Host ""

$confirmation = Read-Host "Proceed with cleanup? (Y/N)"
if ($confirmation -ne "Y" -and $confirmation -ne "y") {
    Write-Host "Cleanup cancelled." -ForegroundColor Yellow
    exit 0
}

Write-Host ""
Write-Host "CLEANUP IN PROGRESS..." -ForegroundColor Cyan
Write-Host "------------------------------------------------------"

# 1. Stop Windows Update service
Write-Host "[1/6] Stopping Windows Update service..." -ForegroundColor Green
Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
Write-Host "      Done - Windows Update service stopped" -ForegroundColor Green

# 2. Clean Windows Update cache
Write-Host "[2/6] Cleaning Windows Update cache..." -ForegroundColor Green
$UpdateFiles = Get-ChildItem -Path $UpdatePath -Force -ErrorAction SilentlyContinue
$UpdateCount = 0
foreach ($file in $UpdateFiles) {
    Remove-Item -Path $file.FullName -Force -Recurse -ErrorAction SilentlyContinue
    $UpdateCount++
}
Write-Host ("      Done - Removed {0} items from Update cache" -f $UpdateCount) -ForegroundColor Green

# 3. Clean Windows Temp folder
Write-Host "[3/6] Cleaning Windows Temp folder..." -ForegroundColor Green
$TempFiles = Get-ChildItem -Path $TempPath -Force -ErrorAction SilentlyContinue
$TempCount = 0
foreach ($file in $TempFiles) {
    Remove-Item -Path $file.FullName -Force -Recurse -ErrorAction SilentlyContinue
    $TempCount++
}
Write-Host ("      Done - Removed {0} items from Windows Temp" -f $TempCount) -ForegroundColor Green

# 4. Clean User Temp folder
Write-Host "[4/6] Cleaning User Temp folder..." -ForegroundColor Green
$UserTempFiles = Get-ChildItem -Path $UserTemp -Force -ErrorAction SilentlyContinue
$UserTempCount = 0
foreach ($file in $UserTempFiles) {
    Remove-Item -Path $file.FullName -Force -Recurse -ErrorAction SilentlyContinue
    $UserTempCount++
}
Write-Host ("      Done - Removed {0} items from User Temp" -f $UserTempCount) -ForegroundColor Green

# 5. Clear Prefetch (optional - helps with boot performance)
Write-Host "[5/6] Clearing Prefetch cache..." -ForegroundColor Green
$PrefetchFiles = Get-ChildItem -Path $PrefetchPath -Force -ErrorAction SilentlyContinue
$PrefetchCount = 0
foreach ($file in $PrefetchFiles) {
    Remove-Item -Path $file.FullName -Force -ErrorAction SilentlyContinue
    $PrefetchCount++
}
Write-Host ("      Done - Cleared {0} prefetch items" -f $PrefetchCount) -ForegroundColor Green

# 6. Clean Windows Update logs
Write-Host "[6/6] Cleaning Windows Update logs..." -ForegroundColor Green
if (Test-Path $LogPath) {
    $LogFiles = Get-ChildItem -Path $LogPath -Filter "*.log" -Force -ErrorAction SilentlyContinue
    $LogCount = 0
    foreach ($file in $LogFiles) {
        Clear-Content -Path $file.FullName -Force -ErrorAction SilentlyContinue
        $LogCount++
    }
    Write-Host ("      Done - Cleaned {0} log files" -f $LogCount) -ForegroundColor Green
}
else {
    Write-Host "      Skipped - log path not found" -ForegroundColor Yellow
}

# Restart Windows Update service
Write-Host ""
Write-Host "Restarting Windows Update service..." -ForegroundColor Green
Start-Service -Name wuauserv -ErrorAction SilentlyContinue
Write-Host "Done - Windows Update service restarted" -ForegroundColor Green

Write-Host ""
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host "CLEANUP COMPLETE!" -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "NEXT STEPS for boot issues:" -ForegroundColor Yellow
Write-Host "  1. Run Disk Cleanup utility (cleanmgr.exe)"
Write-Host "  2. Check Storage > Cleanup recommendations in Settings"
Write-Host "  3. Run: sfc /scannow (System File Checker)"
Write-Host "  4. Run: DISM /Online /Cleanup-Image /RestoreHealth"
Write-Host "  5. Restart your computer"
Write-Host ""
Write-Host "If boot issues persist, consider:" -ForegroundColor Yellow
Write-Host "  - Check Windows Update History for failed updates"
Write-Host "  - Uninstall recent updates if a specific one caused issues"
Write-Host "  - Run Windows Startup Repair (F11 during boot)"
Write-Host ""
Write-Host "Press any key to exit..." -ForegroundColor Gray
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
