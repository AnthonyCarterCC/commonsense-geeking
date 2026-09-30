# ============================================
# M365 Admin + Defender Softening Script (PS7)
# Run as Administrator
# ============================================

Write-Host "===== Starting Admin Environment Setup =====" -ForegroundColor Cyan

# -----------------------------
# 1. Install Required Modules
# -----------------------------
$modules = @(
    "Microsoft.Graph",
    "ExchangeOnlineManagement",
    "MSOnline",
    "Defender"
)

foreach ($mod in $modules) {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
        Write-Host "Installing module: $mod" -ForegroundColor Yellow
        Install-Module $mod -Scope AllUsers -Force -AllowClobber
    } else {
        Write-Host "$mod already installed" -ForegroundColor Green
    }
}

# Import Defender via Windows PowerShell bridge
Import-Module Defender -UseWindowsPowerShell -ErrorAction Stop

# -----------------------------
# 2. Connect to M365 Services
# -----------------------------
Write-Host "`nConnecting to Microsoft 365..." -ForegroundColor Cyan

# Graph (modern auth)
Connect-MgGraph -Scopes "DeviceManagementConfiguration.ReadWrite.All","SecurityEvents.ReadWrite.All"

# Exchange Online
Connect-ExchangeOnline

# Legacy (if needed for admin tasks)
try {
    Connect-MsolService
} catch {
    Write-Warning "MSOnline connection skipped (optional)"
}

# -----------------------------
# 3. Defender Softening
# -----------------------------
Write-Host "`nApplying Defender tuning..." -ForegroundColor Cyan

function Set-SafeMpPreference {
    param ($Name, $Value)
    try {
        Set-MpPreference @{$Name = $Value} -ErrorAction Stop
        Write-Host "Set $Name = $Value" -ForegroundColor Green
    }
    catch {
        Write-Warning "Failed to set $Name"
    }
}

# ASR Rules → Audit
$asrRules = @(
    "D4F940AB-401B-4EFC-AADC-AD5F3C50688A",
    "3B576869-A4EC-4529-8536-B80A7769E899",
    "BE9BA2D9-53EA-4CDC-84E5-9B1EEEE46550",
    "D3E037E1-3EB8-44C8-A917-57927947596D"
)

foreach ($rule in $asrRules) {
    Add-MpPreference -AttackSurfaceReductionRules_Ids $rule `
                     -AttackSurfaceReductionRules_Actions AuditMode
}

Write-Host "ASR rules softened" -ForegroundColor Green

# -----------------------------
# 4. Exclusions (EDIT THESE)
# -----------------------------
$paths = @(
    "C:\DevTools",
    "C:\Installers"
)

$processes = @(
    "msiexec.exe",
    "setup.exe"
)

foreach ($p in $paths) {
    Add-MpPreference -ExclusionPath $p
}

foreach ($proc in $processes) {
    Add-MpPreference -ExclusionProcess $proc
}

# -----------------------------
# 5. Performance tuning
# -----------------------------
Set-SafeMpPreference "ScanAvgCPULoadFactor" 50
Set-SafeMpPreference "DisableScanningMappedNetworkDrivesForFullScan" $true

# -----------------------------
# 6. Cloud protection
# -----------------------------
Set-SafeMpPreference "MAPSReporting" "Advanced"
Set-SafeMpPreference "CloudBlockLevel" "Default"

# -----------------------------
# 7. Controlled Folder Access
# -----------------------------
Set-SafeMpPreference "EnableControlledFolderAccess" "AuditMode"

# -----------------------------
# 8. Ensure protection ON
# -----------------------------
Set-SafeMpPreference "DisableRealtimeMonitoring" $false

# -----------------------------
# 9. Office / App Admin Tweaks
# -----------------------------
Write-Host "`nApplying Office-friendly settings..." -ForegroundColor Cyan

# Reduce SmartScreen blocking (still warns)
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer" `
    -Name "SmartScreenEnabled" -Value "Warn" -Force

# Optional: Allow Office macros (if needed)
# *** Only enable if business requires ***
# Set-ItemProperty -Path "HKCU:\Software\Microsoft\Office\16.0\Word\Security" `
#    -Name "VBAWarnings" -Value 1

# -----------------------------
# 10. Summary
# -----------------------------
Write-Host "`n===== CONFIG SUMMARY =====" -ForegroundColor Cyan

Get-MpPreference | Select-Object `
    DisableRealtimeMonitoring,
    ScanAvgCPULoadFactor,
    EnableControlledFolderAccess,
    CloudBlockLevel |
Format-Table

Write-Host "`n✅ Environment Ready for Admin Use" -ForegroundColor Green
``