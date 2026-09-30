# ============================================================
#  Configure-DefenderQuiet.ps1
#  Makes Microsoft Defender less intrusive / lower overhead
#  Run as Administrator in PowerShell
# ============================================================

#Requires -RunAsAdministrator

Write-Host "`n=== Microsoft Defender - Low Intrusion Config ===" -ForegroundColor Cyan
Write-Host "Running as Administrator: OK`n" -ForegroundColor Green

# ── 1. Disable Tamper Protection (required before changing other settings)
# Note: This must be done manually in Windows Security UI first if it's on.
# The script will attempt it but may be blocked if Tamper Protection is active.
Write-Host "[1/6] Disabling Tamper Protection..." -ForegroundColor Yellow
try {
    Set-MpPreference -DisableTamperProtection $true
    Write-Host "      Done." -ForegroundColor Green
} catch {
    Write-Host "      Could not disable via script. Go to:" -ForegroundColor Red
    Write-Host "      Windows Security > Virus & threat protection > Manage settings > Tamper Protection" -ForegroundColor Gray
}

# ── 2. Turn off Cloud-delivered Protection & Automatic Sample Submission
Write-Host "[2/6] Disabling cloud features & sample submission..." -ForegroundColor Yellow
Set-MpPreference -MAPSReporting Disabled               # Microsoft MAPS / cloud protection
Set-MpPreference -SubmitSamplesConsent NeverSend        # Never send file samples to Microsoft
Set-MpPreference -DisableBlockAtFirstSeen $true         # Disable block-at-first-seen
Write-Host "      Done." -ForegroundColor Green

# ── 3. Reduce real-time protection aggressiveness (keeps it ON but quieter)
Write-Host "[3/6] Tuning real-time protection..." -ForegroundColor Yellow
Set-MpPreference -DisableRealtimeMonitoring $false      # Keep real-time ON (safer)
Set-MpPreference -DisableIOAVProtection $false          # Keep download scanning ON
Set-MpPreference -DisableScriptScanning $false          # Keep script scanning ON
Set-MpPreference -RealTimeScanDirection Both            # Scan incoming & outgoing
Set-MpPreference -DisableCpuThrottleOnIdleScans $false  # Allow throttle on idle (less CPU)
Set-MpPreference -ScanAvgCPULoadFactor 20               # Limit CPU usage to 20% during scans
Write-Host "      Done." -ForegroundColor Green

# ── 4. Suppress non-critical notifications
Write-Host "[4/6] Suppressing non-critical notifications..." -ForegroundColor Yellow
# These registry keys control Windows Security notification suppression
$regPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender Security Center\Notifications"
If (!(Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
Set-ItemProperty -Path $regPath -Name "DisableNotifications"           -Value 0  # Keep critical ones
Set-ItemProperty -Path $regPath -Name "DisableEnhancedNotifications"   -Value 1  # Hide verbose alerts
Write-Host "      Done." -ForegroundColor Green

# ── 5. Exclusions — add common high-noise folders
#    Edit this list to match your own trusted folders
Write-Host "[5/6] Adding exclusions for common trusted folders..." -ForegroundColor Yellow

$exclusions = @(
    # Development
    "$env:USERPROFILE\source",
    "$env:USERPROFILE\projects",
    "$env:USERPROFILE\repos",
    "$env:USERPROFILE\.npm",
    "$env:USERPROFILE\.cargo",
    "$env:LOCALAPPDATA\nvim-data",

    # Virtual Machines
    "$env:USERPROFILE\VirtualBox VMs",
    "$env:USERPROFILE\VMware",
    "$env:USERPROFILE\Hyper-V",

    # Games (common launchers)
    "C:\Program Files (x86)\Steam\steamapps",
    "C:\Program Files\Epic Games",

    # Temporary / build artifacts
    "$env:TEMP",
    "$env:LOCALAPPDATA\Temp"
)

foreach ($path in $exclusions) {
    if (Test-Path $path) {
        Add-MpPreference -ExclusionPath $path
        Write-Host "      Excluded: $path" -ForegroundColor Gray
    }
}
Write-Host "      Done." -ForegroundColor Green

# ── 6. Schedule scans for low-activity times (Task Scheduler)
Write-Host "[6/6] Configuring scheduled scan to run only when idle..." -ForegroundColor Yellow
try {
    $taskPath = "\Microsoft\Windows\Windows Defender\"
    $taskName = "Windows Defender Scheduled Scan"

    $task = Get-ScheduledTask -TaskPath $taskPath -TaskName $taskName -ErrorAction Stop

    # Only run if idle for 30+ minutes, stop if no longer idle
    $settings = New-ScheduledTaskSettingsSet `
        -RunOnlyIfIdle `
        -IdleDuration  (New-TimeSpan -Minutes 30) `
        -IdleWaitTimeout (New-TimeSpan -Hours 1) `
        -StopIfGoingOffIdle `
        -Priority 7   # Below-normal priority

    Set-ScheduledTask -TaskPath $taskPath -TaskName $taskName -Settings $settings | Out-Null
    Write-Host "      Done. Scans will only run after 30 min idle." -ForegroundColor Green
} catch {
    Write-Host "      Could not modify scheduled task: $_" -ForegroundColor Red
}

# ── Summary
Write-Host "`n=== Configuration Complete ===" -ForegroundColor Cyan
Write-Host @"

Changes applied:
  [x] Tamper Protection     — disabled (if allowed)
  [x] Cloud / MAPS          — disabled
  [x] Sample submission     — never send
  [x] CPU scan limit        — 20%
  [x] Verbose notifications — suppressed
  [x] Folder exclusions     — added
  [x] Scheduled scan        — idle-only, low priority

To verify settings run:
  Get-MpPreference | Select-Object MAPSReporting, SubmitSamplesConsent, ScanAvgCPULoadFactor, ExclusionPath

To add more exclusions manually:
  Add-MpPreference -ExclusionPath "C:\Program Files\VideoLAN\VLC"

"@ -ForegroundColor White
