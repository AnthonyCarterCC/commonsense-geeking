# Remove-OneDriveApps.ps1
# Removes all applications with "OneDrive" in the name
# Run as Administrator for full effect

#Requires -RunAsAdministrator

Write-Host "=== OneDrive App Removal Script ===" -ForegroundColor Cyan
Write-Host ""

# -------------------------------------------------------
# 1. Uninstall traditional OneDrive setup (Win32)
# -------------------------------------------------------
Write-Host "[1/4] Checking for traditional OneDrive installation..." -ForegroundColor Yellow

$oneDriveExe = @(
    "$env:SystemRoot\System32\OneDriveSetup.exe",
    "$env:SystemRoot\SysWOW64\OneDriveSetup.exe",
    "$env:LocalAppData\Microsoft\OneDrive\OneDriveSetup.exe"
)

foreach ($exe in $oneDriveExe) {
    if (Test-Path $exe) {
        Write-Host "  Found: $exe — running uninstaller..." -ForegroundColor Gray
        try {
            Start-Process $exe -ArgumentList "/uninstall" -Wait -NoNewWindow
            Write-Host "  Uninstalled successfully." -ForegroundColor Green
        } catch {
            Write-Warning "  Failed to run uninstaller: $_"
        }
    }
}

# -------------------------------------------------------
# 2. Remove AppX / UWP packages (current user)
# -------------------------------------------------------
Write-Host ""
Write-Host "[2/4] Removing OneDrive AppX packages (current user)..." -ForegroundColor Yellow

$userPackages = Get-AppxPackage -Name "*OneDrive*" -ErrorAction SilentlyContinue

if ($userPackages) {
    foreach ($pkg in $userPackages) {
        Write-Host "  Removing: $($pkg.Name) [$($pkg.PackageFullName)]" -ForegroundColor Gray
        try {
            Remove-AppxPackage -Package $pkg.PackageFullName -ErrorAction Stop
            Write-Host "  Removed." -ForegroundColor Green
        } catch {
            Write-Warning "  Could not remove $($pkg.Name): $_"
        }
    }
} else {
    Write-Host "  No AppX OneDrive packages found for current user." -ForegroundColor Gray
}

# -------------------------------------------------------
# 3. Remove AppX provisioned packages (all future users)
# -------------------------------------------------------
Write-Host ""
Write-Host "[3/4] Removing provisioned OneDrive AppX packages (all users)..." -ForegroundColor Yellow

$provPackages = Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -like "*OneDrive*" }

if ($provPackages) {
    foreach ($pkg in $provPackages) {
        Write-Host "  Removing provisioned: $($pkg.DisplayName)" -ForegroundColor Gray
        try {
            Remove-AppxProvisionedPackage -Online -PackageName $pkg.PackageName -ErrorAction Stop
            Write-Host "  Removed." -ForegroundColor Green
        } catch {
            Write-Warning "  Could not remove provisioned package $($pkg.DisplayName): $_"
        }
    }
} else {
    Write-Host "  No provisioned OneDrive packages found." -ForegroundColor Gray
}

# -------------------------------------------------------
# 4. Clean up leftover files and registry entries
# -------------------------------------------------------
Write-Host ""
Write-Host "[4/4] Cleaning up leftover files and registry entries..." -ForegroundColor Yellow

# Kill any running OneDrive processes first
Get-Process -Name "OneDrive" -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2

# Folders to remove
$foldersToRemove = @(
    "$env:UserProfile\OneDrive",
    "$env:LocalAppData\Microsoft\OneDrive",
    "$env:ProgramData\Microsoft OneDrive",
    "$env:SystemRoot\SysWOW64\OneDriveSetup.exe",
    "$env:SystemRoot\System32\OneDriveSetup.exe"
)

foreach ($folder in $foldersToRemove) {
    if (Test-Path $folder) {
        Write-Host "  Removing: $folder" -ForegroundColor Gray
        try {
            Remove-Item -Path $folder -Recurse -Force -ErrorAction Stop
            Write-Host "  Removed." -ForegroundColor Green
        } catch {
            Write-Warning "  Could not remove $folder: $_"
        }
    }
}

# Registry keys to remove
$registryKeys = @(
    "HKCU:\Software\Microsoft\OneDrive",
    "HKLM:\Software\Microsoft\OneDrive",
    "HKLM:\Software\WOW6432Node\Microsoft\OneDrive"
)

foreach ($key in $registryKeys) {
    if (Test-Path $key) {
        Write-Host "  Removing registry key: $key" -ForegroundColor Gray
        try {
            Remove-Item -Path $key -Recurse -Force -ErrorAction Stop
            Write-Host "  Removed." -ForegroundColor Green
        } catch {
            Write-Warning "  Could not remove registry key $key: $_"
        }
    }
}

# Remove OneDrive from Explorer's sidebar (registry)
$clsidKeys = @(
    "HKCR:\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}",
    "HKCR:\Wow6432Node\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}"
)

foreach ($key in $clsidKeys) {
    if (Test-Path $key) {
        try {
            Set-ItemProperty -Path $key -Name "System.IsPinnedToNameSpaceTree" -Value 0 -ErrorAction SilentlyContinue
            Write-Host "  Hidden OneDrive from Explorer sidebar." -ForegroundColor Green
        } catch {
            Write-Warning "  Could not update Explorer sidebar key: $_"
        }
    }
}

# -------------------------------------------------------
# Done
# -------------------------------------------------------
Write-Host ""
Write-Host "=== Removal Complete ===" -ForegroundColor Cyan
Write-Host "OneDrive has been removed. A restart may be required to complete cleanup." -ForegroundColor White
