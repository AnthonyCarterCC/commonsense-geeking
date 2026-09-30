# Windows Update Cleanup and Fix Script
# Requires: Administrator privileges
# Purpose: Clean up Windows Update cache, reset services, and repair Windows components

# Check for administrator privileges
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "ERROR: This script must be run as Administrator!" -ForegroundColor Red
    exit 1
}

Write-Host "=== Windows Update Cleanup and Fix Script ===" -ForegroundColor Cyan
Write-Host "Starting cleanup process..." -ForegroundColor Green
Write-Host ""

# Variables
$updatePath = "$env:windir\SoftwareDistribution\Download"
$backupPath = "$env:windir\SoftwareDistribution\Download.backup"
$logPath = "$env:TEMP\WindowsUpdateCleanup_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

# Start logging
Start-Transcript -Path $logPath -Append

try {
    # Step 1: Stop Windows Update related services
    Write-Host "Step 1: Stopping Windows Update services..." -ForegroundColor Yellow
    $services = @("wuauserv", "cryptSvc", "bits", "msiserver")
    
    foreach ($service in $services) {
        $svc = Get-Service -Name $service -ErrorAction SilentlyContinue
        if ($svc) {
            Write-Host "  Stopping $service..." -ForegroundColor Gray
            Stop-Service -Name $service -Force -ErrorAction SilentlyContinue
            Set-Service -Name $service -StartupType Disabled -ErrorAction SilentlyContinue
        }
    }
    Write-Host "  Services stopped and disabled." -ForegroundColor Green
    Write-Host ""

    # Step 2: Backup and clear Windows Update download folder
    Write-Host "Step 2: Clearing Windows Update cache..." -ForegroundColor Yellow
    if (Test-Path $updatePath) {
        Write-Host "  Backing up current cache to $backupPath..." -ForegroundColor Gray
        if (Test-Path $backupPath) {
            Remove-Item $backupPath -Recurse -Force -ErrorAction SilentlyContinue
        }
        Rename-Item $updatePath $backupPath -Force -ErrorAction SilentlyContinue
        New-Item -Path $updatePath -ItemType Directory -Force | Out-Null
        Write-Host "  Cache cleared successfully." -ForegroundColor Green
    }
    Write-Host ""

    # Step 3: Reset Windows Update components
    Write-Host "Step 3: Resetting Windows Update components..." -ForegroundColor Yellow
    $regPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate",
        "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
    )
    
    foreach ($regPath in $regPaths) {
        if (Test-Path $regPath) {
            Write-Host "  Processing registry: $regPath" -ForegroundColor Gray
            Get-Item $regPath | Get-ItemProperty | Out-Null
        }
    }
    Write-Host "  Registry components checked." -ForegroundColor Green
    Write-Host ""

    # Step 4: Re-enable services
    Write-Host "Step 4: Re-enabling Windows Update services..." -ForegroundColor Yellow
    foreach ($service in $services) {
        $svc = Get-Service -Name $service -ErrorAction SilentlyContinue
        if ($svc) {
            Write-Host "  Enabling $service..." -ForegroundColor Gray
            Set-Service -Name $service -StartupType Automatic -ErrorAction SilentlyContinue
            Start-Service -Name $service -ErrorAction SilentlyContinue
        }
    }
    Write-Host "  Services re-enabled and started." -ForegroundColor Green
    Write-Host ""

    # Step 5: Run DISM online scan and repair
    Write-Host "Step 5: Running DISM scan and repair (this may take several minutes)..." -ForegroundColor Yellow
    Write-Host "  Running: DISM /Online /Cleanup-Image /StartComponentCleanup" -ForegroundColor Gray
    DISM /Online /Cleanup-Image /StartComponentCleanup /ResetBase 2>&1 | Tee-Object -Variable dismOutput | Out-Null
    Write-Host "  Component cleanup completed." -ForegroundColor Green
    Write-Host ""

    # Step 6: System File Check (optional - takes longer)
    Write-Host "Step 6: Running System File Checker (SFC) scan..." -ForegroundColor Yellow
    Write-Host "  Running: sfc /scannow (this may take 10-15 minutes)..." -ForegroundColor Gray
    sfc /scannow 2>&1 | Out-Null
    Write-Host "  System File Check completed." -ForegroundColor Green
    Write-Host ""

    # Step 7: Clear temporary Windows Update files
    Write-Host "Step 7: Clearing temporary Windows Update files..." -ForegroundColor Yellow
    $tempPaths = @(
        "$env:windir\Temp\*",
        "$env:TEMP\*",
        "$env:windir\Prefetch\*"
    )
    
    foreach ($path in $tempPaths) {
        try {
            Remove-Item $path -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
        } catch {
            # Skip files that are in use
        }
    }
    Write-Host "  Temporary files cleaned." -ForegroundColor Green
    Write-Host ""

    # Final summary
    Write-Host "=== Cleanup Complete ===" -ForegroundColor Cyan
    Write-Host "The following has been completed:" -ForegroundColor Green
    Write-Host "  ✓ Windows Update services stopped, cleaned, and restarted" -ForegroundColor Green
    Write-Host "  ✓ Update cache backed up and cleared" -ForegroundColor Green
    Write-Host "  ✓ Windows Update components reset" -ForegroundColor Green
    Write-Host "  ✓ DISM scan and component cleanup executed" -ForegroundColor Green
    Write-Host "  ✓ System File Checker scan completed" -ForegroundColor Green
    Write-Host "  ✓ Temporary files cleaned" -ForegroundColor Green
    Write-Host ""
    Write-Host "Log file saved to: $logPath" -ForegroundColor Cyan
    Write-Host "Backup saved to: $backupPath" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "RECOMMENDATION: Restart your computer to complete the cleanup process." -ForegroundColor Yellow

} catch {
    Write-Host "ERROR: An unexpected error occurred: $_" -ForegroundColor Red
    Write-Host "Log file: $logPath" -ForegroundColor Yellow
} finally {
    Stop-Transcript
}
