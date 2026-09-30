# Remove Dell Bloatware and Unnecessary Utilities
# Run as Administrator
# Usage: .\Remove-DellBloatware.ps1

#Requires -RunAsAdministrator

Write-Host "=== Dell Bloatware Removal Script ===" -ForegroundColor Cyan
Write-Host "This will remove common Dell pre-installed apps and utilities" -ForegroundColor Yellow
Write-Host ""

# Define Dell apps to remove - comment out any you want to keep
$DellAppsToRemove = @(
    # Dell MyDell and registration
    "Dell.Dell",
    "Dell.DellHub",
    "DellInc.DellPowerManager",
    "DellInc.DellOptimizer",
    "DellInc.DellDigitalDelivery",
    "Dell.DellSupportAssistActivity",
    
    # Dell utilities
    "DellInc.DellPowerManager",
    "Dell.Client.Consumer.HID",
    "Dell.DellDataVault",
    "DellInc.ContactITSupport"
)

# Define programs to uninstall via Control Panel/Programs
$DellProgramsToRemove = @(
    "Dell Command Update",
    "Dell SupportAssist",
    "Dell SupportAssistRemediation",
    "Dell Data Protection",
    "SupportAssist Player",
    "Dell Product Registration",
    "Dell Backup and Recovery",
    "Dell Digital Delivery",
    "Dell Power Manager",
    "Dell Optimizer",
    "Dell Touchpad",
    "Dell Dock",
    "Dell Audio",
    "Dell Graphics",
    "Dell System Update",
    "Alienware Command Center",
    "Alienware Peripherals",
    "McAfee LiveUpdate",
    "McAfee Total Protection",
    "Norton AntiVirus",
    "Norton Security",
    "My Dell",
    "Dell Update",
    "Dell Factory Tools",
    "Dell Backup and Recovery Manager",
    "Wave MaxxAudio",
    "Waves MaxxAudio Pro",
    "Realtek Audio"
)

# Remove AppX packages (if any)
Write-Host "Removing Dell AppX packages..." -ForegroundColor Green
foreach ($App in $DellAppsToRemove) {
    try {
        $Package = Get-AppxPackage -Name "*$App*" -ErrorAction SilentlyContinue
        if ($Package) {
            Write-Host "  Removing AppX: $App" -ForegroundColor Yellow
            $Package | Remove-AppxPackage -ErrorAction SilentlyContinue | Out-Null
        }
    }
    catch {
        Write-Host "  Error with AppX $App`: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# Remove programs via Windows installer
Write-Host ""
Write-Host "Removing Dell programs via Windows Installer..." -ForegroundColor Green

foreach ($Program in $DellProgramsToRemove) {
    try {
        $InstalledProgram = Get-WmiObject -Class Win32_Product | Where-Object { $_.Name -like "*$Program*" }
        
        if ($InstalledProgram) {
            foreach ($Item in $InstalledProgram) {
                Write-Host "  Uninstalling: $($Item.Name)" -ForegroundColor Yellow
                $Item.Uninstall() | Out-Null
            }
        }
    }
    catch {
        Write-Host "  Error with $Program`: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# Alternative method: Use wmic for Programs and Features
Write-Host ""
Write-Host "Scanning Programs and Features (alternative method)..." -ForegroundColor Green

foreach ($Program in $DellProgramsToRemove) {
    try {
        $Apps = Get-Package -Name "*$Program*" -ErrorAction SilentlyContinue
        if ($Apps) {
            foreach ($App in $Apps) {
                Write-Host "  Found and removing: $($App.Name)" -ForegroundColor Yellow
                Uninstall-Package -InputObject $App -Force -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
            }
        }
    }
    catch {
        # Silently skip if not found or error occurs
    }
}

# Remove scheduled tasks related to Dell
Write-Host ""
Write-Host "Removing Dell scheduled tasks..." -ForegroundColor Green

$DellTasks = @(
    "Dell SupportAssist",
    "Dell Command Update",
    "Dell Product Registration",
    "Dell System Update",
    "DellOptimizer",
    "DellPowerManager"
)

foreach ($Task in $DellTasks) {
    try {
        $ScheduledTasks = Get-ScheduledTask -TaskName "*$Task*" -ErrorAction SilentlyContinue
        if ($ScheduledTasks) {
            foreach ($ScheduledTask in $ScheduledTasks) {
                Write-Host "  Disabling task: $($ScheduledTask.TaskName)" -ForegroundColor Yellow
                Disable-ScheduledTask -TaskName $ScheduledTask.TaskName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
            }
        }
    }
    catch {
        Write-Host "  Error with task $Task`: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# Remove Dell services
Write-Host ""
Write-Host "Disabling Dell services..." -ForegroundColor Green

$DellServices = @(
    "DellClientManagementService",
    "DellClientUpdate",
    "DellDataVault",
    "DellSystemDetect",
    "smstsmgr" # SCCM/MDM related
)

foreach ($Service in $DellServices) {
    try {
        $Svc = Get-Service -Name $Service -ErrorAction SilentlyContinue
        if ($Svc) {
            Write-Host "  Stopping and disabling: $Service" -ForegroundColor Yellow
            Stop-Service -Name $Service -Force -ErrorAction SilentlyContinue | Out-Null
            Set-Service -Name $Service -StartupType Disabled -ErrorAction SilentlyContinue | Out-Null
        }
    }
    catch {
        Write-Host "  Error with service $Service`: $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "=== Cleanup Complete ===" -ForegroundColor Cyan
Write-Host "Restart your computer for all changes to take effect." -ForegroundColor Yellow
Write-Host ""
Write-Host "Note: Some Dell utilities may require manual removal if they're" -ForegroundColor Gray
Write-Host "integrated with Windows. Uninstall from Control Panel if needed." -ForegroundColor Gray
