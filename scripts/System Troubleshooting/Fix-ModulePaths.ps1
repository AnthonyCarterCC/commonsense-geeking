#Requires -RunAsAdministrator
<#
    Fix-ModulePaths.ps1

    Moves PowerShell modules currently installed under the OneDrive-redirected
    Documents folder into the AllUsers scope (C:\Program Files\PowerShell\Modules),
    then removes the OneDrive-synced CurrentUser copies.

    Run this in an elevated PowerShell 7 window:
        Right-click PowerShell 7 -> Run as Administrator
        cd to the folder containing this script
        .\Fix-ModulePaths.ps1
#>

$ErrorActionPreference = 'Stop'

Write-Host "Checking currently installed resources..." -ForegroundColor Cyan
$modules = Get-InstalledPSResource | Where-Object { $_.InstalledLocation -like "*OneDrive*" }

if (-not $modules) {
    Write-Host "No modules found installed under a OneDrive path. Nothing to do." -ForegroundColor Yellow
    return
}

foreach ($m in $modules) {
    $name = $m.Name
    Write-Host "`n--- $name ($($m.Version)) ---" -ForegroundColor Green

    try {
        Write-Host "Installing $name to AllUsers scope..."
        Install-PSResource -Name $name -Scope AllUsers -Reinstall -TrustRepository -ErrorAction Stop

        Write-Host "Removing OneDrive-synced CurrentUser copy of $name..."
        Uninstall-PSResource -Name $name -Scope CurrentUser -ErrorAction Stop
    }
    catch {
        Write-Warning "Failed to migrate $name`: $_"
    }
}

Write-Host "`nDone. Verifying result:" -ForegroundColor Cyan
Get-InstalledPSResource | Select-Object Name, Version, InstalledLocation | Format-Table -AutoSize

Write-Host "`nFrom now on, always install/update with -Scope AllUsers (as Administrator) to avoid OneDrive." -ForegroundColor Cyan
