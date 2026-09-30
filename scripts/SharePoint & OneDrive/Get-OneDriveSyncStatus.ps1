# Diagnose OneDrive sync status and identify large libraries
# Requires PnP.PowerShell and connection to M365

param(
    [switch]$ShowLargeSites
)

# Check OneDrive process
Write-Host "OneDrive Status:" -ForegroundColor Cyan
$OneDriveProcess = Get-Process onedrive -ErrorAction SilentlyContinue
if ($OneDriveProcess) {
    Write-Host "  ✓ OneDrive running (PID: $($OneDriveProcess.Id))"
    Write-Host "  Memory: $($OneDriveProcess.WorkingSet / 1MB -as [int]) MB"
} else {
    Write-Host "  ✗ OneDrive NOT running"
}

# Check sync database integrity
Write-Host "`nSync Database:" -ForegroundColor Cyan
$SyncDbPath = "$env:LOCALAPPDATA\Microsoft\OneDrive\sync_engine"
if (Test-Path $SyncDbPath) {
    $SyncDbSize = (Get-ChildItem $SyncDbPath -Recurse | Measure-Object -Property Length -Sum).Sum / 1MB
    Write-Host "  ✓ Database exists (~$($SyncDbSize -as [int]) MB)"
} else {
    Write-Host "  ✗ No sync database (fresh/corrupted)"
}

# Check for pending sync queue
Write-Host "`nSync Queue:" -ForegroundColor Cyan
$QueuePath = "$env:LOCALAPPDATA\Microsoft\OneDrive\logs\Personal_SyncEngine"
$QueueFile = Get-ChildItem $QueuePath -Filter "*queue*" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($QueueFile) {
    $QueueSize = $QueueFile.Length / 1MB
    if ($QueueSize -gt 50) {
        Write-Host "  ⚠ Large queue: $($QueueSize -as [int]) MB (may cause lag)"
    } else {
        Write-Host "  ✓ Queue size: $($QueueSize -as [int]) MB"
    }
} else {
    Write-Host "  ✓ No backlog detected"
}

# List synced SharePoint sites (if running)
if ($OneDriveProcess) {
    Write-Host "`nSharePoint Sites Synced:" -ForegroundColor Cyan
    
    $OneDrivePath = "$env:USERPROFILE\OneDrive"
    $MountPoints = Get-ChildItem $OneDrivePath -Directory -ErrorAction SilentlyContinue | 
        Where-Object { $_.Name -like "*sharepoint*" -or $_.Name -match "^\d+$" }
    
    foreach ($Mount in $MountPoints) {
        $Size = (Get-ChildItem $Mount.FullPath -Recurse -Force -ErrorAction SilentlyContinue | 
                 Measure-Object -Property Length -Sum).Sum / 1GB
        
        if ($Size -gt 50) {
            Write-Host "  ⚠ $($Mount.Name): $($Size -as [int]) GB (LARGE - consider disabling sync)" -ForegroundColor Yellow
        } else {
            Write-Host "  • $($Mount.Name): $($Size -as [int]) GB"
        }
    }
} else {
    Write-Host "  (OneDrive not running - cannot enumerate)"
}

Write-Host "`n--- Next Steps ---" -ForegroundColor Magenta
Write-Host "1. If >50 MB queue: Run Clear-OneDriveCrash.ps1"
Write-Host "2. If >2 large sites: Uncheck largest in Settings → Accounts → Manage"
Write-Host "3. Monitor memory usage - reboot if >500MB"
