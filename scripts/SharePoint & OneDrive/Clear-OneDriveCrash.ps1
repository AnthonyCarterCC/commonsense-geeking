# Clear OneDrive cache and reset sync database
# Fixes crashing with multiple/large SharePoint site syncs

# Stop OneDrive
Write-Host "Stopping OneDrive..." -ForegroundColor Cyan
Get-Process onedrive -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2

# Clear OneDrive cache
$OneDrivePath = "$env:USERPROFILE\OneDrive"
$CachePath = "$env:LOCALAPPDATA\Microsoft\OneDrive"
$SyncPath = "$env:LOCALAPPDATA\Microsoft\OneDrive\logs"

Write-Host "Clearing cache folders..." -ForegroundColor Cyan

if (Test-Path "$CachePath\cache.sqlite") {
    Remove-Item "$CachePath\cache.sqlite" -Force -ErrorAction SilentlyContinue
    Write-Host "  ✓ Removed cache.sqlite"
}

if (Test-Path "$CachePath\settings.json") {
    Remove-Item "$CachePath\settings.json" -Force -ErrorAction SilentlyContinue
    Write-Host "  ✓ Removed settings.json"
}

# Clear sync database (critical for corruption)
$SyncDbPath = "$CachePath\sync_engine"
if (Test-Path $SyncDbPath) {
    Remove-Item $SyncDbPath -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "  ✓ Removed sync database"
}

# Clear logs
if (Test-Path $SyncPath) {
    Remove-Item "$SyncPath\*" -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "  ✓ Cleared logs"
}

# Restart OneDrive
Write-Host "Restarting OneDrive..." -ForegroundColor Cyan
& "$env:LOCALAPPDATA\Microsoft\OneDrive\OneDrive.exe" /background
Start-Sleep -Seconds 3

Write-Host "`nOneDrive reset complete." -ForegroundColor Green

Write-Host "`n⚠ LARGE SHAREPOINT SITES - Recommendations:" -ForegroundColor Yellow
Write-Host "   You have >8 sites with 2 large ones. To prevent re-crash:"
Write-Host ""
Write-Host "   1. UNCHECK the 2 largest SharePoint site syncs temporarily"
Write-Host "   2. Let the smaller ones stabilize (monitor for 10+ minutes)"
Write-Host "   3. Gradually re-enable larger sites one at a time"
Write-Host ""
Write-Host "   OR use web-based access for the largest sites instead of sync"
Write-Host ""
Write-Host "   Check Settings → Accounts → Manage → Storage to see sync details"
