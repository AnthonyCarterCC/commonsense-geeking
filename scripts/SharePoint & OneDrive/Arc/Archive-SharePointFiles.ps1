#Requires -Modules PnP.PowerShell
<#
.SYNOPSIS
    Archives files older than a configured age threshold from a SharePoint document
    library into a dedicated Archive site collection.

.DESCRIPTION
    - Connects to the tenant using app-only (certificate) auth via PnP PowerShell.
    - Checks whether the Archive site exists; creates it if not (Communication Site).
    - Enumerates files in the source library older than ArchiveThresholdYears
      (based on Modified date), oldest first.
    - Limits to TestFileLimit files for a safe test run (set to 0 or remove for full runs).
    - Copies each file to the Archive site, preserving the source folder structure.
    - Verifies the copy landed before touching the original.
    - Deletes the original ONLY if DryRun = false in config.json.
    - Logs every action to a CSV for audit / rollback reference.

.NOTES
    Run the DryRun=true pass first. Review archive-log.csv. Only flip DryRun to
    false once you're happy with what it *would* have done.
#>

param(
    [string]$ConfigPath = "$PSScriptRoot\config.json"
)

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Load config
# ---------------------------------------------------------------------------
if (-not (Test-Path $ConfigPath)) {
    throw "Config file not found at $ConfigPath"
}
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json

$cutoffDate   = (Get-Date).AddYears(-1 * $cfg.ArchiveThresholdYears)
$logPath      = $cfg.LogPath
$log          = New-Object System.Collections.Generic.List[Object]

function Write-Log {
    param($FileName, $SourcePath, $DestPath, $SizeKB, $ModifiedDate, $Status, $Detail = "")
    $log.Add([PSCustomObject]@{
        Timestamp    = (Get-Date).ToString("s")
        FileName     = $FileName
        SourcePath   = $SourcePath
        DestPath     = $DestPath
        SizeKB       = $SizeKB
        ModifiedDate = $ModifiedDate
        Status       = $Status
        Detail       = $Detail
        DryRun       = $cfg.DryRun
    })
}

# ---------------------------------------------------------------------------
# Visibility helpers - every phase and every connection prints a timestamped
# line, so the console always shows what stage the run is in and when it last
# did something, rather than going silent with no way to tell connected /
# reading / copying / stuck apart.
# ---------------------------------------------------------------------------
function Get-Timestamp { (Get-Date).ToString("HH:mm:ss") }

function Write-Phase {
    param([string]$Message)
    Write-Host "[$(Get-Timestamp)] ==> $Message" -ForegroundColor Yellow
}

# Throttles per-item progress lines so a big run doesn't scroll continuously -
# prints at most once every 5000 items OR every 5 seconds, whichever comes
# first, plus always on the final item. Errors are never throttled - they're
# written separately, unconditionally, wherever they occur.
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
    # Connects AND proves the connection is actually live with a real
    # round-trip call (Get-PnPWeb) - Connect-PnPOnline alone can succeed
    # locally without confirming the site is actually reachable.
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

Write-Host "=== SharePoint Archive Run ===" -ForegroundColor Cyan
Write-Host "Threshold : files older than $($cfg.ArchiveThresholdYears) years (before $($cutoffDate.ToShortDateString()))"
Write-Host "Test limit: $($cfg.TestFileLimit) files"
Write-Host "Dry run   : $($cfg.DryRun)"
Write-Host ""

# ---------------------------------------------------------------------------
# Connect - tenant admin (to check/create the Archive site)
# ---------------------------------------------------------------------------
Connect-PnPOnlineAndVerify -Url $cfg.TenantAdminUrl -ClientId $cfg.ClientId -Thumbprint $cfg.Thumbprint -Tenant $cfg.Tenant -Label "tenant admin"

# ---------------------------------------------------------------------------
# Check / create Archive site
# ---------------------------------------------------------------------------
$archiveSite = Get-PnPTenantSite -Url $cfg.ArchiveSiteUrl -ErrorAction SilentlyContinue

if (-not $archiveSite) {
    Write-Host "Archive site not found. Creating: $($cfg.ArchiveSiteUrl)" -ForegroundColor Yellow
    if (-not $cfg.DryRun) {
        New-PnPSite -Type CommunicationSite -Title $cfg.ArchiveSiteTitle -Url $cfg.ArchiveSiteUrl -Owner $cfg.SiteOwner -Wait
        Write-Host "Archive site created." -ForegroundColor Green
    } else {
        Write-Host "[DRY RUN] Would create archive site here." -ForegroundColor Magenta
    }
} else {
    Write-Host "Archive site already exists: $($cfg.ArchiveSiteUrl)" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Connect - source site
# ---------------------------------------------------------------------------
Connect-PnPOnlineAndVerify -Url $cfg.SourceSiteUrl -ClientId $cfg.ClientId -Thumbprint $cfg.Thumbprint -Tenant $cfg.Tenant -Label "source site"

# ---------------------------------------------------------------------------
# Enumerate files older than threshold
# ---------------------------------------------------------------------------
Write-Phase "Scanning library '$($cfg.SourceLibrary)' for files older than $($cfg.ArchiveThresholdYears) years..."
$scanStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

$list = Get-PnPList -Identity $cfg.SourceLibrary -Includes RootFolder
$sourceLibraryRoot = $list.RootFolder.ServerRelativeUrl   # e.g. /sites/Creative/Shared Documents - NOT necessarily same as the library's display name
Write-Host "[$(Get-Timestamp)] Library found: '$($list.Title)' - now reading its contents page by page (progress every 5000 items or 5s below)..." -ForegroundColor DarkGray

# Full file inventory (files only, no date filter yet) - used both to derive
# the eligible-for-archiving set below AND for the by-year summary printed
# at the end of the run. Piped through ForEach-Object (rather than assigned
# straight from Get-PnPListItem) so each page prints a progress line as it
# streams through, instead of going silent until the entire library is read.
$script:scanSeen = 0
$scanGate = New-ProgressGate
$allFiles = Get-PnPListItem -List $list -PageSize 500 -Fields "FileLeafRef","FileRef","Modified","File_x0020_Size","FSObjType" |
    ForEach-Object {
        $script:scanSeen++
        if (Test-ProgressGate -Gate $scanGate -Count $script:scanSeen -Total -1) {
            Write-Host ("  [$(Get-Timestamp)] ...read {0:N0} items so far ({1:N0}s elapsed)" -f $script:scanSeen, $scanStopwatch.Elapsed.TotalSeconds) -ForegroundColor DarkGray
        }
        $_
    } |
    Where-Object { $_.FieldValues.FSObjType -eq 0 }             # files only, not folders

Write-Host ("[$(Get-Timestamp)] Scan complete: {0:N0} items read, {1:N0} are files - took {2:N0}s." -f $script:scanSeen, $allFiles.Count, $scanStopwatch.Elapsed.TotalSeconds) -ForegroundColor Green

$items = $allFiles |
    Where-Object { $_.FieldValues.Modified -lt $cutoffDate } |
    Sort-Object { $_.FieldValues.Modified }

# ---------------------------------------------------------------------------
# By-year file inventory (source library) - last 5 calendar years
# ---------------------------------------------------------------------------
$currentYear = (Get-Date).Year
$yearBreakdown = for ($y = $currentYear; $y -gt ($currentYear - 5); $y--) {
    $filesInYear = $allFiles | Where-Object { $_.FieldValues.Modified.Year -eq $y }
    $sizeBytes = ($filesInYear | ForEach-Object { $_.FieldValues.File_x0020_Size } | Measure-Object -Sum).Sum
    [PSCustomObject]@{
        Year   = $y
        Count  = $filesInYear.Count
        SizeGB = [math]::Round(($sizeBytes / 1GB), 2)
    }
}
$olderFiles = $allFiles | Where-Object { $_.FieldValues.Modified.Year -le ($currentYear - 5) }
$olderSizeBytes = ($olderFiles | ForEach-Object { $_.FieldValues.File_x0020_Size } | Measure-Object -Sum).Sum
$olderSizeGB = [math]::Round(($olderSizeBytes / 1GB), 2)

if (-not $items -or $items.Count -eq 0) {
    Write-Host "No files older than the threshold were found." -ForegroundColor Green
    Write-Host "`nFile inventory by year (source library, all files regardless of archive status):" -ForegroundColor Cyan
    foreach ($yb in $yearBreakdown) {
        Write-Host ("{0}   {1:N0} files   {2:N2} GB" -f $yb.Year, $yb.Count, $yb.SizeGB)
    }
    Write-Host ("Older than {0}   {1:N0} files   {2:N2} GB" -f ($currentYear - 5), $olderFiles.Count, $olderSizeGB)
    return
}

$totalFound = $items.Count
if ($cfg.TestFileLimit -gt 0) {
    $items = $items | Select-Object -First $cfg.TestFileLimit
}

$limitNote = if ($cfg.TestFileLimit -gt 0 -and $items.Count -lt $totalFound) { " (test limit applied)" } else { " (full run - no limit)" }
Write-Host "Found $totalFound eligible files. Processing $($items.Count)$limitNote." -ForegroundColor Cyan
Write-Host ""

# ---------------------------------------------------------------------------
# Process each file: copy -> verify -> (optionally) delete original
#
# IMPORTANT: this uses ONE plain (default) PnP connection at a time, switched
# between source/archive site only at clean phase boundaries below - not named
# -Connection objects juggled mid-loop. An earlier version used separate
# -ReturnConnection objects for source/archive and reconnected mid-loop on every
# iteration; that caused Get-PnPFile to report files as missing even when they
# demonstrably existed (confirmed by running the identical command manually right
# after). Root cause not fully confirmed, but the fix - plain sequential
# reconnects, matching exactly what worked when run manually - resolved it.
# ---------------------------------------------------------------------------
$archiveWebRelative = ([Uri]$cfg.ArchiveSiteUrl).AbsolutePath
$tenantRootUrl      = ([Uri]$cfg.SourceSiteUrl).GetLeftPart([UriPartial]::Authority)

$moved = 0; $skipped = 0; $errors = 0

# Build the full list of planned operations up front (no network calls yet)
$plan = @()
foreach ($item in $items) {
    $fileRef  = $item.FieldValues.FileRef            # e.g. /sites/SOURCESITE/Documents/FolderA/file.docx
    $fileName = $item.FieldValues.FileLeafRef
    $modified = $item.FieldValues.Modified
    $sizeKB   = [math]::Round(($item.FieldValues.File_x0020_Size / 1KB), 1)

    # relative path within the library, preserved into the archive library
    # (stripped against the library's real root folder, not its display name)
    $relativeInLibrary = $fileRef -replace [regex]::Escape("$sourceLibraryRoot/"), ""

    $plan += [PSCustomObject]@{
        FileRef          = $fileRef
        FileName         = $fileName
        Modified         = $modified
        SizeKB           = $sizeKB
        RelativeInLibrary = $relativeInLibrary
        # Split-Path returns backslash-separated paths on Windows even when given a
        # forward-slash SharePoint path - normalize back to forward slashes or every
        # destination/verification path built from this silently breaks.
        FolderRelative   = ((Split-Path $relativeInLibrary -Parent) -replace '\\', '/')
    }
}

if ($cfg.DryRun) {
    foreach ($p in $plan) {
        Write-Host "[DRY RUN] Would copy: $($p.FileRef)" -ForegroundColor Magenta
        Write-Log -FileName $p.FileName -SourcePath $p.FileRef -DestPath "" -SizeKB $p.SizeKB -ModifiedDate $p.Modified -Status "DRY-RUN-SKIPPED"
        $skipped++
    }
} else {
    # -------------------------------------------------------------------
    # Phase 1: connect to ARCHIVE once - resolve real library root + create
    # all destination folders needed
    # -------------------------------------------------------------------
    Connect-PnPOnlineAndVerify -Url $cfg.ArchiveSiteUrl -ClientId $cfg.ClientId -Thumbprint $cfg.Thumbprint -Tenant $cfg.Tenant -Label "archive site"

    $archiveListObj = Get-PnPList -Identity $cfg.ArchiveLibrary -Includes RootFolder
    $archiveLibraryRoot = $archiveListObj.RootFolder.ServerRelativeUrl
    $archiveLibrarySiteRelative = $archiveLibraryRoot -replace [regex]::Escape("$archiveWebRelative/"), ""

    $foldersCreated = @{}
    $uniqueFolderCount = @($plan | Select-Object -ExpandProperty FolderRelative -Unique | Where-Object { $_ }).Count
    Write-Phase "Resolving/creating $uniqueFolderCount unique destination folder(s) (progress every 5000 or 5s below)..."
    $folderStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $folderGate = New-ProgressGate
    $folderCount = 0
    foreach ($p in $plan) {
        $destServerRelativeFolder = "$archiveLibraryRoot/$($p.FolderRelative)".TrimEnd("/")
        $p | Add-Member -NotePropertyName DestFolder -NotePropertyValue $destServerRelativeFolder
        $p | Add-Member -NotePropertyName DestPath -NotePropertyValue "$destServerRelativeFolder/$($p.FileName)"

        if ($p.FolderRelative -and -not $foldersCreated.ContainsKey($p.FolderRelative)) {
            Resolve-PnPFolder -SiteRelativePath "$archiveLibrarySiteRelative/$($p.FolderRelative)" | Out-Null
            $foldersCreated[$p.FolderRelative] = $true
            $folderCount++
            if (Test-ProgressGate -Gate $folderGate -Count $folderCount -Total $uniqueFolderCount) {
                Write-Host ("  [$(Get-Timestamp)] ...folder {0:N0} of {1:N0} ready ({2:N0}s elapsed)" -f $folderCount, $uniqueFolderCount, $folderStopwatch.Elapsed.TotalSeconds) -ForegroundColor DarkGray
            }
        }
    }
    Write-Host "[$(Get-Timestamp)] All destination folders ready." -ForegroundColor Green

    # -------------------------------------------------------------------
    # Phase 2: connect to SOURCE once - trigger every copy job
    # -------------------------------------------------------------------
    Connect-PnPOnlineAndVerify -Url $cfg.SourceSiteUrl -ClientId $cfg.ClientId -Thumbprint $cfg.Thumbprint -Tenant $cfg.Tenant -Label "source site"

    $triggered = @()
    $copyIndex = 0
    $totalPlan = $plan.Count
    $copyGate = New-ProgressGate
    Write-Phase "Triggering $totalPlan copy job(s) (progress every 5000 or 5s below)..."
    foreach ($p in $plan) {
        $copyIndex++
        try {
            $destAbsoluteFolder = "$tenantRootUrl$($p.DestFolder)"
            Copy-PnPFile -SourceUrl $p.FileRef -TargetUrl $destAbsoluteFolder -Force -OverwriteIfAlreadyExists
            if (Test-ProgressGate -Gate $copyGate -Count $copyIndex -Total $totalPlan) {
                Write-Host "[$(Get-Timestamp)] [$copyIndex/$totalPlan] Copy triggered: $($p.FileName)" -ForegroundColor DarkCyan
            }
            $triggered += $p
        } catch {
            Write-Host "[$(Get-Timestamp)] [$copyIndex/$totalPlan] Error triggering copy for $($p.FileName) : $($_.Exception.Message)" -ForegroundColor Red
            Write-Log -FileName $p.FileName -SourcePath $p.FileRef -DestPath $p.DestPath -SizeKB $p.SizeKB -ModifiedDate $p.Modified -Status "ERROR" -Detail $_.Exception.Message
            $errors++
        }
    }

    if ($triggered.Count -gt 0) {
        Write-Phase "Waiting for $($triggered.Count) copy job(s) to land on the archive site..."
        for ($waited = 5; $waited -le 30; $waited += 5) {
            Start-Sleep -Seconds 5
            Write-Host ("  [$(Get-Timestamp)] ...waited {0}s/30s" -f $waited) -ForegroundColor DarkGray
        }
    }

    # -------------------------------------------------------------------
    # Phase 3: connect to ARCHIVE once - verify every copy landed
    # -------------------------------------------------------------------
    Connect-PnPOnlineAndVerify -Url $cfg.ArchiveSiteUrl -ClientId $cfg.ClientId -Thumbprint $cfg.Thumbprint -Tenant $cfg.Tenant -Label "archive site (verify)"

    $verified = @()
    $verifyIndex = 0
    $totalTriggered = $triggered.Count
    $verifyGate = New-ProgressGate
    Write-Phase "Verifying $totalTriggered copy job(s) landed (progress every 5000 or 5s below)..."
    foreach ($p in $triggered) {
        $verifyIndex++
        $verify = $null
        for ($attempt = 1; $attempt -le 4; $attempt++) {
            $verify = Get-PnPFile -Url $p.DestPath -ErrorAction SilentlyContinue
            if ($verify) { break }
            Write-Host "  [$(Get-Timestamp)] [$verifyIndex/$totalTriggered] not landed yet, retry $attempt/4 in 15s: $($p.FileName)" -ForegroundColor DarkGray
            Start-Sleep -Seconds 15
        }
        if ($verify) {
            $verified += $p
            if (Test-ProgressGate -Gate $verifyGate -Count $verifyIndex -Total $totalTriggered) {
                Write-Host "[$(Get-Timestamp)] [$verifyIndex/$totalTriggered] Verified: $($p.FileName)" -ForegroundColor DarkGreen
            }
        } else {
            Write-Host "[$(Get-Timestamp)] [$verifyIndex/$totalTriggered] Copy verification failed, original NOT deleted: $($p.FileName)" -ForegroundColor Red
            Write-Log -FileName $p.FileName -SourcePath $p.FileRef -DestPath $p.DestPath -SizeKB $p.SizeKB -ModifiedDate $p.Modified -Status "VERIFY-FAILED"
            $errors++
        }
    }

    # -------------------------------------------------------------------
    # Phase 4: connect to SOURCE once - delete originals that verified
    # -------------------------------------------------------------------
    if ($verified.Count -gt 0) {
        Connect-PnPOnlineAndVerify -Url $cfg.SourceSiteUrl -ClientId $cfg.ClientId -Thumbprint $cfg.Thumbprint -Tenant $cfg.Tenant -Label "source site (delete)"

        $deleteIndex = 0
        $totalVerified = $verified.Count
        $deleteGate = New-ProgressGate
        Write-Phase "Deleting $totalVerified verified original(s) (progress every 5000 or 5s below)..."
        foreach ($p in $verified) {
            $deleteIndex++
            try {
                Remove-PnPFile -ServerRelativeUrl $p.FileRef -Force
                if (Test-ProgressGate -Gate $deleteGate -Count $deleteIndex -Total $totalVerified) {
                    Write-Host "[$(Get-Timestamp)] [$deleteIndex/$totalVerified] Archived: $($p.FileName)" -ForegroundColor Green
                }
                Write-Log -FileName $p.FileName -SourcePath $p.FileRef -DestPath $p.DestPath -SizeKB $p.SizeKB -ModifiedDate $p.Modified -Status "ARCHIVED"
                $moved++
            } catch {
                Write-Host "[$(Get-Timestamp)] [$deleteIndex/$totalVerified] Error deleting original $($p.FileName) : $($_.Exception.Message)" -ForegroundColor Red
                Write-Log -FileName $p.FileName -SourcePath $p.FileRef -DestPath $p.DestPath -SizeKB $p.SizeKB -ModifiedDate $p.Modified -Status "ERROR" -Detail $_.Exception.Message
                $errors++
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Write log + summary
# ---------------------------------------------------------------------------
$log | Export-Csv -Path $logPath -NoTypeInformation -Append -Force

Write-Host "`n=== Summary ===" -ForegroundColor Cyan
Write-Host "Eligible files found : $totalFound"
Write-Host "Processed this run   : $($items.Count)"
Write-Host "Archived             : $moved"
Write-Host "Skipped (dry run)    : $skipped"
Write-Host "Errors               : $errors"
Write-Host "Log written to       : $logPath"

Write-Host "`nFile inventory by year (source library, all files regardless of archive status):" -ForegroundColor Cyan
foreach ($yb in $yearBreakdown) {
    Write-Host ("{0}   {1:N0} files   {2:N2} GB" -f $yb.Year, $yb.Count, $yb.SizeGB)
}
Write-Host ("Older than {0}   {1:N0} files   {2:N2} GB" -f ($currentYear - 5), $olderFiles.Count, $olderSizeGB)
