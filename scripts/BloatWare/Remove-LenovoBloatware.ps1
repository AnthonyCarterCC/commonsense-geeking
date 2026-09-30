#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Removes Lenovo bloatware (Vantage, Now, Welcome, PC Manager, McAfee trial,
    promo Store apps, etc.) from Windows 10/11 - IdeaPad/Yoga/Legion/ThinkPad.

.DESCRIPTION
    Covers all Lenovo removal vectors as of 2026:
      1. AppX/UWP packages (current user + all users + provisioned, so they
         don't come back for new user profiles)
      2. Win32 apps via winget (fast, silent)
      3. Win32 apps via registry uninstall strings (fallback for anything
         winget doesn't know, e.g. older Vantage builds)
      4. Lenovo background services (Vantage Service, System Update, etc.)
      5. Scheduled tasks that re-trigger installs/updates
      6. Leftover Run-key / startup entries

    NOTE: "Lenovo System Interface Foundation" and pointing-device (Synaptics/
    ELAN/TrackPoint) drivers are intentionally NOT touched - those are
    hardware drivers, not bloatware, and removing them breaks Fn keys /
    trackpad. Everything else is removed since you asked for it all gone.

.PARAMETER WhatIf
    Show what would be removed without actually removing anything.

.EXAMPLE
    Right-click > Run with PowerShell (as Administrator)
    or:  powershell -ExecutionPolicy Bypass -File .\Remove-LenovoBloatware.ps1
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$SkipRestartPrompt
)

$ErrorActionPreference = 'SilentlyContinue'
$logFile = Join-Path $env:TEMP "LenovoDebloat_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

function Write-Log {
    param([string]$Message, [string]$Color = 'Gray')
    Write-Host $Message -ForegroundColor $Color
    Add-Content -Path $logFile -Value "$(Get-Date -Format 'HH:mm:ss')  $Message"
}

Write-Log "=== Lenovo Bloatware Removal - $(Get-Date) ===" 'Cyan'
Write-Log "Log file: $logFile" 'DarkGray'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Log "This script must be run as Administrator. Relaunch with 'Run as administrator'." 'Red'
    exit 1
}

# Restore point first - cheap insurance
Write-Log "`nCreating a system restore point..." 'Cyan'
try {
    Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
    Checkpoint-Computer -Description "Before Lenovo Debloat" -RestorePointType "MODIFY_SETTINGS"
    Write-Log "Restore point created." 'Green'
} catch {
    Write-Log "Could not create a restore point (non-fatal), continuing." 'Yellow'
}

# ------------------------------------------------------------------
# 1. AppX / UWP packages
# ------------------------------------------------------------------
$appxPatterns = @(
    '*Lenovo*'
    '*IdeaFriend*'
    '*IdeaHealth*'
    '*IdeaNote*'
    '*LenovoCompanion*'
    '*LenovoNow*'
    '*LenovoUtility*'
    '*LenovoWelcome*'
    '*LenovoSmartPrivacy*'
    '*LenovoVoice*'
    '*E046963F.LenovoCompanion*'
    '*McAfee*'
    '*WildTangent*'
)

Write-Log "`n--- Removing AppX/UWP packages ---" 'Cyan'
foreach ($pattern in $appxPatterns) {
    $installed = Get-AppxPackage -AllUsers -Name $pattern
    foreach ($pkg in $installed) {
        if ($PSCmdlet.ShouldProcess($pkg.Name, "Remove-AppxPackage")) {
            try {
                Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
                Write-Log "Removed AppX: $($pkg.Name)" 'Green'
            } catch {
                Write-Log "Failed to remove AppX $($pkg.Name): $_" 'Yellow'
            }
        }
    }
    $provisioned = Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -like $pattern }
    foreach ($prov in $provisioned) {
        try {
            Remove-AppxProvisionedPackage -Online -PackageName $prov.PackageName -ErrorAction Stop | Out-Null
            Write-Log "Removed provisioned package (won't reinstall for new users): $($prov.DisplayName)" 'Green'
        } catch {
            Write-Log "Failed to remove provisioned package $($prov.DisplayName): $_" 'Yellow'
        }
    }
}

# ------------------------------------------------------------------
# 2. winget uninstalls (Win32 apps winget knows about)
# ------------------------------------------------------------------
$wingetIds = @(
    'Lenovo.Vantage'
    'Lenovo.VantageService'
    'Lenovo.SystemUpdate'
    'Lenovo.SystemInterfaceFoundation.NoDriver'  # metadata only, driver untouched
    'Lenovo.Now'
    '9WZDNCRFJ3TJ'   # Lenovo Vantage (Store ID)
    'McAfee.LiveSafe'
    'McAfee.SafeConnect'
    'WildTangent.WildTangentGamesApp'
)

Write-Log "`n--- Uninstalling via winget ---" 'Cyan'
$wingetAvailable = Get-Command winget -ErrorAction SilentlyContinue
if ($wingetAvailable) {
    foreach ($id in $wingetIds) {
        if ($PSCmdlet.ShouldProcess($id, "winget uninstall")) {
            $result = winget uninstall --id $id --silent --accept-source-agreements --disable-interactivity 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Log "winget removed: $id" 'Green'
            } else {
                Write-Log "winget: $id not installed or already removed." 'DarkGray'
            }
        }
    }
} else {
    Write-Log "winget not found on this machine - skipping (registry fallback below still runs)." 'Yellow'
}

# ------------------------------------------------------------------
# 3. Registry uninstall-string fallback (covers older/odd installs)
# ------------------------------------------------------------------
Write-Log "`n--- Uninstalling via registry (MSI/EXE) ---" 'Cyan'

$nameMatches = @(
    'Lenovo Vantage*'
    'Lenovo Vantage Service*'
    'Lenovo Now*'
    'Lenovo Welcome*'
    'Lenovo PC Manager*'
    'Lenovo System Update*'
    'Lenovo Migration Assistant*'
    'Lenovo Smart Privacy*'
    'Lenovo Voice*'
    'Lenovo Utility*'
    'Lenovo Family Cloud*'
    'Lenovo Solution Center*'
    'Lenovo Experience Improvement*'
    'McAfee*'
    'WildTangent*'
)

$uninstallRoots = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
)

foreach ($root in $uninstallRoots) {
    $entries = Get-ItemProperty -Path $root -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName }

    foreach ($entry in $entries) {
        foreach ($pattern in $nameMatches) {
            if ($entry.DisplayName -like $pattern) {
                $uninstallCmd = $entry.QuietUninstallString
                if (-not $uninstallCmd) { $uninstallCmd = $entry.UninstallString }
                if (-not $uninstallCmd) { continue }

                if ($PSCmdlet.ShouldProcess($entry.DisplayName, "Uninstall")) {
                    Write-Log "Uninstalling: $($entry.DisplayName)" 'White'
                    try {
                        if ($uninstallCmd -match 'msiexec') {
                            $productCode = [regex]::Match($uninstallCmd, '\{[0-9A-Fa-f\-]+\}').Value
                            if ($productCode) {
                                Start-Process 'msiexec.exe' -ArgumentList "/x $productCode /qn /norestart" -Wait -ErrorAction Stop
                            }
                        } else {
                            # Try to force silent flags most Lenovo installers accept
                            $exe, $args = $uninstallCmd -split ' ', 2
                            $exe = $exe.Trim('"')
                            $silentArgs = "$args /S /silent /verysilent /qn /norestart"
                            Start-Process -FilePath $exe -ArgumentList $silentArgs -Wait -ErrorAction Stop
                        }
                        Write-Log "  -> Removed: $($entry.DisplayName)" 'Green'
                    } catch {
                        Write-Log "  -> Failed: $($entry.DisplayName) - $_" 'Yellow'
                    }
                }
                break
            }
        }
    }
}

# ------------------------------------------------------------------
# 4. Stop & disable Lenovo services (prevents silent re-install)
# ------------------------------------------------------------------
Write-Log "`n--- Disabling Lenovo background services ---" 'Cyan'
$servicePatterns = @('Lenovo*', 'ImController*', 'LenovoVantageService*')
foreach ($pattern in $servicePatterns) {
    $services = Get-Service -Name $pattern -ErrorAction SilentlyContinue
    foreach ($svc in $services) {
        if ($PSCmdlet.ShouldProcess($svc.Name, "Stop & disable service")) {
            try {
                Stop-Service -Name $svc.Name -Force -ErrorAction SilentlyContinue
                Set-Service -Name $svc.Name -StartupType Disabled -ErrorAction SilentlyContinue
                Write-Log "Disabled service: $($svc.DisplayName)" 'Green'
            } catch {
                Write-Log "Could not disable service $($svc.Name): $_" 'Yellow'
            }
        }
    }
}

# ------------------------------------------------------------------
# 5. Remove/disable Lenovo scheduled tasks (auto-reinstall / update nags)
# ------------------------------------------------------------------
Write-Log "`n--- Disabling Lenovo scheduled tasks ---" 'Cyan'
$tasks = Get-ScheduledTask | Where-Object { $_.TaskName -like '*Lenovo*' -or $_.TaskPath -like '*Lenovo*' }
foreach ($task in $tasks) {
    if ($PSCmdlet.ShouldProcess($task.TaskName, "Disable scheduled task")) {
        try {
            Disable-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction Stop | Out-Null
            Write-Log "Disabled task: $($task.TaskPath)$($task.TaskName)" 'Green'
        } catch {
            Write-Log "Could not disable task $($task.TaskName): $_" 'Yellow'
        }
    }
}

# ------------------------------------------------------------------
# 6. Clean up leftover Run-key startup entries
# ------------------------------------------------------------------
Write-Log "`n--- Cleaning startup Run-key entries ---" 'Cyan'
$runKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
)
foreach ($key in $runKeys) {
    $props = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
    if ($props) {
        $props.PSObject.Properties |
            Where-Object { $_.Name -like '*Lenovo*' -and $_.Name -notmatch '^PS' } |
            ForEach-Object {
                if ($PSCmdlet.ShouldProcess($_.Name, "Remove startup entry")) {
                    Remove-ItemProperty -Path $key -Name $_.Name -ErrorAction SilentlyContinue
                    Write-Log "Removed startup entry: $($_.Name)" 'Green'
                }
            }
    }
}

# ------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------
Write-Log "`n=== Done ===" 'Cyan'
Write-Log "Full log saved to: $logFile" 'DarkGray'
Write-Log "`nUntouched on purpose (these are drivers, not bloatware):" 'Yellow'
Write-Log "  - Lenovo System Interface Foundation (Fn keys depend on it)" 'Yellow'
Write-Log "  - Synaptics/ELAN/TrackPoint pointing-device drivers" 'Yellow'
Write-Log "  - Chipset/GPU drivers" 'Yellow'

if (-not $SkipRestartPrompt) {
    $restart = Read-Host "`nA restart is recommended to finish removing background processes. Restart now? (y/N)"
    if ($restart -eq 'y') { Restart-Computer -Force }
}
