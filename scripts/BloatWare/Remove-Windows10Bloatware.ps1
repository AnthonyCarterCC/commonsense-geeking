# Remove Windows 10 Bloatware Apps - Clean transition to Windows 11
# Run as Administrator
# Usage: .\Remove-Windows10Bloatware.ps1

#Requires -RunAsAdministrator

Write-Host "=== Windows 10 Bloatware Removal Script ===" -ForegroundColor Cyan
Write-Host "This will remove common Windows 10 pre-installed apps" -ForegroundColor Yellow
Write-Host ""

# Define apps to remove - feel free to comment out any you want to keep
$AppsToRemove = @(
    # Microsoft bloatware
    "Microsoft.BingSearch",
    "Microsoft.GetHelp",
    "Microsoft.Getstarted",
    "Microsoft.MicrosoftOfficeHub",
    "Microsoft.MicrosoftSolitaireCollection",
    "Microsoft.News",
    "Microsoft.OneConnect",
    "Microsoft.People",
    "Microsoft.SkypeApp",
    "Microsoft.Wallet",
    "Microsoft.Windows.Photos",
    "Microsoft.WindowsAlarms",
    "Microsoft.WindowsCamera",
    "Microsoft.WindowsFeedbackHub",
    "Microsoft.WindowsMaps",
    "Microsoft.WindowsSoundRecorder",
    "Microsoft.ZuneMusic",
    "Microsoft.ZuneVideo",
    "Microsoft.3DBuilder",
    "Microsoft.AppConnector",
    "Microsoft.RemoteDesktop",
    "Microsoft.Print3D",
    
    # Messaging and comms
    "Microsoft.Messaging",
    
    # Games and entertainment
    "Microsoft.MixedReality.Portal",
    "Microsoft.MinecraftUWP",
    "Microsoft.GamingApp",
    "Microsoft.XboxApp",
    
    # Other
    "Microsoft.YourPhone"
    # "Microsoft.WindowsStore" # CAUTION: Disables Store - uncomment if you want to remove it
)

# Remove provisioned packages (for all users including new accounts)
Write-Host "Removing provisioned packages..." -ForegroundColor Green
foreach ($App in $AppsToRemove) {
    try {
        $Packages = Get-AppxProvisionedPackage -Online | Where-Object { $_.PackageName -like "*$App*" }
        if ($Packages) {
            Write-Host "  Removing: $App (provisioned)" -ForegroundColor Yellow
            $Packages | Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Out-Null
        }
    }
    catch {
        Write-Host "  Error with $App (provisioned): $($_.Exception.Message)" -ForegroundColor Red
    }
}

# Remove installed packages (current user)
Write-Host ""
Write-Host "Removing installed packages (current user)..." -ForegroundColor Green
foreach ($App in $AppsToRemove) {
    try {
        $Package = Get-AppxPackage -Name "*$App*" -ErrorAction SilentlyContinue
        if ($Package) {
            Write-Host "  Removing: $App" -ForegroundColor Yellow
            $Package | Remove-AppxPackage -ErrorAction SilentlyContinue | Out-Null
        }
    }
    catch {
        Write-Host "  Error with $App`: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# Optional: Remove Cortana (if you really don't want it)
# Uncomment the lines below if needed
# Write-Host ""
# Write-Host "Attempting to disable Cortana..." -ForegroundColor Green
# Get-AppxPackage -Name "*Cortana*" | Remove-AppxPackage -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "=== Cleanup Complete ===" -ForegroundColor Cyan
Write-Host "Restart your computer for all changes to take effect." -ForegroundColor Yellow
Write-Host ""

# Optional: Show remaining apps
Write-Host "Remaining AppX packages:" -ForegroundColor Cyan
Get-AppxPackage | Select-Object Name | Sort-Object Name
