#Requires -Modules PnP.PowerShell
<#
.SYNOPSIS
    Finds and removes empty folders left behind in a SharePoint library after
    an archive run has moved all the files out of them.

.DESCRIPTION
    Archive-SharePointFiles.ps1 copies files to the archive site and deletes
    the originals, but it never touches the now-empty folder structure left
    behind in the SOURCE library. This script cleans that up.

    A folder is only ever considered "empty" if there are ZERO files anywhere
    in it or any of its subfolders - it never deletes a folder that still
    contains files, directly or nested. Where an entire branch is empty (e.g.
    FolderA/FolderB/FolderC with no files anywhere in that branch), only the
    shallowest folder (FolderA) is removed - deleting it in SharePoint already
    removes its empty subfolders with it, so there's no need to work bottom-up
    one folder at a time.

    Deleted folders go to the site's recycle bin (standard SharePoint
    retention, not gone permanently) - recoverable from there if needed.

    Skips the library's root folder and system folders (e.g. "Forms").

    Safe by default: run with no -Execute switch (or explicitly without it)
    to see what WOULD be removed, with no changes made. Add -Execute to
    actually delete the empty folders.

    Reuses one of the existing per-site config.json files for the site URL,
    library name, and app credentials - no new config needed.

.EXAMPLE
    .\Remove-EmptyFolders.ps1 -ConfigPath ".\Platinum - Digital.json"
    # Dry run - lists what would be removed, changes nothing.

.EXAMPLE
    .\Remove-EmptyFolders.ps1 -ConfigPath ".\Platinum - Digital.json" -Execute
    # Actually removes the empty folders (to the recycle bin).

.NOTES
    Run this against the SOURCE site (same config the main archive script
    uses) AFTER an archive run has completed - the point is to tidy up the
    folder structure left behind once the files inside it have been moved.
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath,

    [switch]$Execute
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $ConfigPath)) {
    throw "Config file not found at $ConfigPath"
}
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json

$logPath = Join-Path (Split-Path $ConfigPath -Parent) "emptyfolder-log-$([System.IO.Path]::GetFileNameWithoutExtension($ConfigPath)).csv"
$log = New-Object System.Collections.Generic.List[Object]

function Write-Log {
    param($FolderPath, $Status, $Detail = "")
    $log.Add([PSCustomObject]@{
        Timestamp   = (Get-Date).ToString("s")
        FolderPath  = $FolderPath
        Status      = $Status
        Detail      = $Detail
        Execute     = [bool]$Execute
    })
}

function Get-Timestamp { (Get-Date).ToString("HH:mm:ss") }

function Write-Phase {
    param([string]$Message)
    Write-Host "[$(Get-Timestamp)] ==> $Message" -ForegroundColor Yellow
}

# Throttles per-item progress lines so a big run doesn't scroll continuously -
# prints at most once every 5000 items OR every 5 seconds, whichever comes
# first, plus always on the final item. Errors are never throttled.
function New-ProgressGate {
    [PSCustomObject]@{ Stopwatch = [System.Diagnostics.Stopwatch]::StartNew(); LastCount = 0 }
}
function Test-ProgressGate {
    param($Gate, [int]$Count, [int]$Total, [int]$EveryN = 5000, [int]$EverySeconds = 5)
    if ($Count -eq $Total -or ($Count - $Gate.LastCount) -ge $EveryN -or $Gate.Stopwatch.Elapsed.TotalSeconds -ge $EverySeconds) {
        $Gate.LastCount = $Count
        $Gate.Stopwatch.Restart()
        return $true
    }
    return $false
}

function Connect-PnPOnlineAndVerify {
    param([string]$Url, [string]$ClientId, [string]$Thumbprint, [string]$Tenant, [string]$Label)
    Write-Phase "Connecting to $Label`: $Url"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        Connect-PnPOnline -Url $Url -ClientId $ClientId -Thumbprint $Thumbprint -Tenant $Tenant
        $web = Get-PnPWeb -ErrorAction Stop
        Write-Host ("[$(Get-Timestamp)] Connected - '{0}' responded in {1:N1}s." -f $web.Title, $sw.Elapsed.TotalSeconds) -ForegroundColor Green
    } catch {
        Write-Host "[$(Get-Timestamp)] FAILED to connect to $Label ($Url): $($_.Exception.Message)" -ForegroundColor Red
        throw
    }
}

Write-Host "=== Empty Folder Cleanup ===" -ForegroundColor Cyan
Write-Host "Site    : $($cfg.SourceSiteUrl)"
Write-Host "Library : $($cfg.SourceLibrary)"
Write-Host "Mode    : $(if ($Execute) { 'EXECUTE (will remove folders - recoverable from the site recycle bin)' } else { 'Dry run - nothing will change' })"
Write-Host ""

Connect-PnPOnlineAndVerify -Url $cfg.SourceSiteUrl -ClientId $cfg.ClientId -Thumbprint $cfg.Thumbprint -Tenant $cfg.Tenant -Label "source site"

$list = Get-PnPList -Identity $cfg.SourceLibrary -Includes RootFolder
$libraryRoot = $list.RootFolder.ServerRelativeUrl

Write-Phase "Scanning '$($cfg.SourceLibrary)' (files and folders, progress every 5000 or 5s below)..."
$scanStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$script:scanSeen = 0
$scanGate = New-ProgressGate

$allItems = Get-PnPListItem -List $list -PageSize 500 -Fields "FileRef","FSObjType" |
    ForEach-Object {
        $script:scanSeen++
        if (Test-ProgressGate -Gate $scanGate -Count $script:scanSeen -Total -1) {
            Write-Host ("  [$(Get-Timestamp)] ...read {0:N0} items so far ({1:N0}s elapsed)" -f $script:scanSeen, $scanStopwatch.Elapsed.TotalSeconds) -ForegroundColor DarkGray
        }
        $_
    }

Write-Host ("[$(Get-Timestamp)] Scan complete: {0:N0} items read in {1:N0}s." -f $script:scanSeen, $scanStopwatch.Elapsed.TotalSeconds) -ForegroundColor Green

$files = $allItems | Where-Object { $_.FieldValues.FSObjType -eq 0 }
$folders = $allItems | Where-Object {
    $_.FieldValues.FSObjType -eq 1 -and
    $_.FieldValues.FileRef -ne $libraryRoot -and                         # never the library root itself
    ($_.FieldValues.FileRef -split '/')[-1] -notin @("Forms")            # skip system folders
}

Write-Host "[$(Get-Timestamp)] Files: $($files.Count)   Folders (excluding root/system): $($folders.Count)" -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# Mark every ancestor path of every file as "has files under it" - a single
# pass over the files (not files x folders), so a folder anywhere in a file's
# path chain is known to be non-empty without an expensive per-folder scan.
# ---------------------------------------------------------------------------
Write-Phase "Identifying empty folders..."
$hasFilesUnder = @{}
foreach ($f in $files) {
    $segments = $f.FieldValues.FileRef -split '/'
    $path = ""
    for ($i = 0; $i -lt $segments.Count - 1; $i++) {
        $path = if ($path) { "$path/$($segments[$i])" } else { $segments[$i] }
        $hasFilesUnder[$path] = $true
    }
}

$emptyCandidates = $folders | Where-Object { -not $hasFilesUnder.ContainsKey($_.FieldValues.FileRef) }

# Keep only the SHALLOWEST empty folder in any empty branch - deleting it in
# SharePoint removes its (also empty) subfolders with it in one operation.
$emptyCandidates = $emptyCandidates | Sort-Object { ($_.FieldValues.FileRef -split '/').Count }
$toRemove = @()
foreach ($c in $emptyCandidates) {
    $isUnderAccepted = $toRemove | Where-Object { $c.FieldValues.FileRef.StartsWith("$($_.FieldValues.FileRef)/") } | Select-Object -First 1
    if (-not $isUnderAccepted) { $toRemove += $c }
}

if ($toRemove.Count -eq 0) {
    Write-Host "[$(Get-Timestamp)] No empty folders found." -ForegroundColor Green
    return
}

Write-Host "[$(Get-Timestamp)] Found $($toRemove.Count) empty folder(s) to remove (of $($folders.Count) total folders scanned)." -ForegroundColor Cyan
Write-Host ""

$removeIndex = 0
$totalToRemove = $toRemove.Count
$removeGate = New-ProgressGate
$removed = 0; $errors = 0
Write-Phase "$(if ($Execute) { 'Removing' } else { 'Previewing removal of' }) $totalToRemove empty folder(s) (progress every 5000 or 5s below)..."

foreach ($folder in $toRemove) {
    $removeIndex++
    $folderPath = $folder.FieldValues.FileRef

    if (-not $Execute) {
        if (Test-ProgressGate -Gate $removeGate -Count $removeIndex -Total $totalToRemove) {
            Write-Host "[$(Get-Timestamp)] [$removeIndex/$totalToRemove] [WHATIF] Would remove: $folderPath" -ForegroundColor Magenta
        }
        Write-Log -FolderPath $folderPath -Status "WHATIF-SKIPPED"
        continue
    }

    try {
        # Deleting by the item's own list-item Id (rather than reconstructing
        # a parent path for Remove-PnPFolder) avoids the server-relative vs
        # site-relative path mismatches that have caused real bugs elsewhere
        # in this project (see PROJECT-HANDOFF.md bugs #2/#5/#7) - no path
        # format ambiguity, it just targets the exact item already in hand.
        # -Recycle sends it to the site recycle bin instead of a permanent delete.
        Remove-PnPListItem -List $list -Identity $folder.Id -Recycle -Force
        if (Test-ProgressGate -Gate $removeGate -Count $removeIndex -Total $totalToRemove) {
            Write-Host "[$(Get-Timestamp)] [$removeIndex/$totalToRemove] Removed: $folderPath" -ForegroundColor Green
        }
        Write-Log -FolderPath $folderPath -Status "REMOVED"
        $removed++
    } catch {
        Write-Host "[$(Get-Timestamp)] [$removeIndex/$totalToRemove] Error removing $folderPath : $($_.Exception.Message)" -ForegroundColor Red
        Write-Log -FolderPath $folderPath -Status "ERROR" -Detail $_.Exception.Message
        $errors++
    }
}

$log | Export-Csv -Path $logPath -NoTypeInformation -Force

Write-Host "`n=== Summary ===" -ForegroundColor Cyan
Write-Host "Empty folders found : $($toRemove.Count)"
Write-Host "Mode                : $(if ($Execute) { 'Executed' } else { 'Dry run only - nothing changed' })"
if ($Execute) {
    Write-Host "Removed             : $removed"
    Write-Host "Errors              : $errors"
    Write-Host "(Removed folders are in the site recycle bin, not gone permanently.)" -ForegroundColor DarkGray
}
Write-Host "Log written to      : $logPath"
if (-not $Execute) {
    Write-Host "`nRerun with -Execute to actually remove these folders." -ForegroundColor Yellow
}
