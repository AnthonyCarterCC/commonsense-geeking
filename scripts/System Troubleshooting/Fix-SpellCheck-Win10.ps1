# Fix Windows 10 Spell-Checking Issues
# Run as Administrator
# Purpose: Restore spell-checking after ShutUp10++ or O&O AppBuster

# Check for admin privileges
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")
if (-not $isAdmin) {
    Write-Host "ERROR: This script must run as Administrator" -ForegroundColor Red
    Write-Host "Right-click PowerShell and select 'Run as administrator'" -ForegroundColor Yellow
    Exit 1
}

Write-Host "=== Windows 10 Spell-Check Repair ===" -ForegroundColor Cyan
Write-Host ""

# Step 1: Clear spell-check cache
Write-Host "[1/4] Clearing spell-check cache..." -ForegroundColor Yellow
$cachePaths = @(
    "$env:AppData\Microsoft\Spelling",
    "$env:LocalAppData\Microsoft\Spell"
)

foreach ($path in $cachePaths) {
    if (Test-Path $path) {
        try {
            Remove-Item "$path\*" -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "  OK: Cleared: $path" -ForegroundColor Green
        }
        catch {
            Write-Host "  WARNING: Could not clear $path (might be in use)" -ForegroundColor Yellow
        }
    }
}
Write-Host ""

# Step 2: Re-enable critical services (ShutUp10++ often disables these)
Write-Host "[2/4] Re-enabling language and search services..." -ForegroundColor Yellow
$services = @(
    "WSearch",
    "SearchIndexer",
    "TextInputManagementService"
)

foreach ($service in $services) {
    try {
        $svc = Get-Service -Name $service -ErrorAction SilentlyContinue
        if ($svc) {
            Set-Service -Name $service -StartupType Automatic -ErrorAction SilentlyContinue
            Start-Service -Name $service -ErrorAction SilentlyContinue
            Write-Host "  OK: Enabled: $service" -ForegroundColor Green
        }
    }
    catch {
        Write-Host "  WARNING: Could not enable $service" -ForegroundColor Yellow
    }
}
Write-Host ""

# Step 3: Check language pack
Write-Host "[3/4] Checking language settings..." -ForegroundColor Yellow
try {
    $langList = Get-WinUserLanguageList
    if ($langList.Count -gt 0) {
        Write-Host "  Current language: $($langList[0].LanguageTag)" -ForegroundColor Cyan
        Write-Host "  OK: Language pack is installed" -ForegroundColor Green
    }
    else {
        Write-Host "  WARNING: No language pack detected" -ForegroundColor Yellow
    }
}
catch {
    Write-Host "  WARNING: Could not read language list" -ForegroundColor Yellow
}
Write-Host ""

# Step 4: Reset OneDrive and related services (sometimes related to spell-check)
Write-Host "[4/4] Resetting search and related services..." -ForegroundColor Yellow
try {
    $svc = Get-Service -Name "WSearch" -ErrorAction SilentlyContinue
    if ($svc) {
        Stop-Service -Name "WSearch" -Force -ErrorAction SilentlyContinue
        Start-Service -Name "WSearch" -ErrorAction SilentlyContinue
        Write-Host "  OK: Restarted Windows Search" -ForegroundColor Green
    }
}
catch {
    Write-Host "  WARNING: Could not restart WSearch" -ForegroundColor Yellow
}
Write-Host ""

# Summary
Write-Host "=== Repair Complete ===" -ForegroundColor Cyan
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "1. Restart your computer"
Write-Host "2. Test spell-check in Notepad, Word, or Edge"
Write-Host ""
Write-Host "If spell-check still doesn't work:" -ForegroundColor Cyan
Write-Host "  - Settings > Time & language > Region & language"
Write-Host "  - Check that your language is listed and installed"
Write-Host "  - If not, add it from Available languages"
Write-Host ""

$restart = Read-Host "Restart computer now? (Y/N)"
if ($restart -eq "Y" -or $restart -eq "y") {
    Write-Host "Restarting in 30 seconds..." -ForegroundColor Yellow
    shutdown /r /t 30 /c "Spell-check repair - restart initiated"
}
else {
    Write-Host "Please restart manually for changes to take effect" -ForegroundColor Yellow
}
