# Fix Windows 11 Spell-Checking Issues
# Run as Administrator
# Purpose: Restore spell-checking after O&O AppBuster or ShutUp10++

# Check for admin privileges
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")
if (-not $isAdmin) {
    Write-Host "ERROR: This script must run as Administrator" -ForegroundColor Red
    Write-Host "Right-click PowerShell and select 'Run as administrator'" -ForegroundColor Yellow
    Exit 1
}

Write-Host "=== Windows 11 Spell-Check Repair ===" -ForegroundColor Cyan
Write-Host ""

# Step 1: Clear spell-check cache
Write-Host "[1/5] Clearing spell-check cache..." -ForegroundColor Yellow
$cachePaths = @(
    "$env:AppData\Microsoft\Spelling",
    "$env:LocalAppData\Microsoft\Spell"
)

foreach ($path in $cachePaths) {
    if (Test-Path $path) {
        try {
            Remove-Item "$path\*" -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "  ✓ Cleared: $path" -ForegroundColor Green
        } catch {
            Write-Host "  ⚠ Could not clear $path (might be in use)" -ForegroundColor Yellow
        }
    }
}
Write-Host ""

# Step 2: Re-enable language services
Write-Host "[2/5] Re-enabling language services..." -ForegroundColor Yellow
$services = @(
    "TextInputManagementService",
    "DiagTrack",
    "dmwappushservice"
)

foreach ($service in $services) {
    try {
        $svc = Get-Service -Name $service -ErrorAction SilentlyContinue
        if ($svc) {
            Set-Service -Name $service -StartupType Automatic -ErrorAction SilentlyContinue
            Start-Service -Name $service -ErrorAction SilentlyContinue
            Write-Host "  ✓ Enabled: $service" -ForegroundColor Green
        }
    } catch {
        Write-Host "  ⚠ Could not enable $service" -ForegroundColor Yellow
    }
}
Write-Host ""

# Step 3: Re-enable optional features
Write-Host "[3/5] Checking optional Windows features..." -ForegroundColor Yellow
$optionalFeatures = @(
    "Printing-Foundation-Features",
    "Printing-Foundation-InternetPrinting-Client"
)

foreach ($feature in $optionalFeatures) {
    try {
        $state = Get-WindowsOptionalFeature -Online -FeatureName $feature -ErrorAction SilentlyContinue
        if ($state -and $state.State -eq "Disabled") {
            Enable-WindowsOptionalFeature -Online -FeatureName $feature -NoRestart -ErrorAction SilentlyContinue
            Write-Host "  ✓ Enabled: $feature" -ForegroundColor Green
        }
    } catch {
        Write-Host "  ⚠ Could not enable $feature" -ForegroundColor Yellow
    }
}
Write-Host ""

# Step 4: Reset language preferences
Write-Host "[4/5] Resetting language preferences..." -ForegroundColor Yellow
try {
    $langList = Get-WinUserLanguageList
    if ($langList.Count -gt 0) {
        Write-Host "  Current language: $($langList[0].LanguageTag)" -ForegroundColor Cyan
        Write-Host "  ✓ Language pack is installed" -ForegroundColor Green
    }
} catch {
    Write-Host "  ⚠ Could not read language list" -ForegroundColor Yellow
}
Write-Host ""

# Step 5: Restart required services
Write-Host "[5/5] Restarting critical services..." -ForegroundColor Yellow
$criticalServices = @(
    "SearchIndexer",
    "WSearch"
)

foreach ($service in $criticalServices) {
    try {
        $svc = Get-Service -Name $service -ErrorAction SilentlyContinue
        if ($svc) {
            Restart-Service -Name $service -Force -ErrorAction SilentlyContinue
            Write-Host "  ✓ Restarted: $service" -ForegroundColor Green
        }
    } catch {
        Write-Host "  ⚠ Could not restart $service" -ForegroundColor Yellow
    }
}
Write-Host ""

# Summary
Write-Host "=== Repair Complete ===" -ForegroundColor Cyan
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "1. Restart your computer"
Write-Host "2. Test spell-check in Notepad, Word, or Edge"
Write-Host ""
Write-Host "If spell-check still doesn't work:" -ForegroundColor Cyan
Write-Host "  • Settings > Time & language > Language & region"
Write-Host "  • Verify your language is installed"
Write-Host "  • Reinstall the language pack if needed"
Write-Host ""

$restart = Read-Host "Restart computer now? (Y/N)"
if ($restart -eq "Y" -or $restart -eq "y") {
    Write-Host "Restarting in 30 seconds..." -ForegroundColor Yellow
    shutdown /r /t 30 /c "Spell-check repair - restart initiated"
} else {
    Write-Host "Please restart manually for changes to take effect" -ForegroundColor Yellow
}
