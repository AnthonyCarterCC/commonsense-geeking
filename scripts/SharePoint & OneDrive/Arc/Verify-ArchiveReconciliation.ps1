#Requires -Modules PnP.PowerShell
<#
.SYNOPSIS
    Read-only reconciliation check for the SharePoint archive process.
    Does NOT copy, delete, or modify anything - safe to run at any time,
    including while Archive-SharePointFiles.ps1 is actively running elsewhere.

.DESCRIPTION
    Compares the source library and archive library file-by-file (by their
    path relative to each library's real root folder) and classifies every
    file into one of three buckets, independent of what archive-log.csv says:

      ARCHIVED_CONFIRMED  - exists in archive, NOT in source. Fully done.
      COPIED_NOT_DELETED  - exists in BOTH. Copy succeeded but original
                             was not removed - needs follow-up.
      NOT_YET_ARCHIVED    - still only in source (may or may not be past
                             the age threshold - both are reported).

.NOTES
    Use this whenever a run may have been interrupted and you don't trust
    archive-log.csv to reflect what actually happened (the main script only
    writes its log once, at the very end of the run).
#>

param(
    [string]$ConfigPath = "$PSScriptRoot\config.json",
    [string]$ReportPath = $null
)

if (-not (Test-Path $ConfigPath)) {
    throw "Config file not found at $ConfigPath"
}
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json

if (-not $ReportPath) {
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($ConfigPath)
    $ReportPath = "$PSScriptRoot\reconciliation-$baseName.csv"
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
    # Connects AND proves it with a real round-trip call (Get-PnPWeb) - see
    # Archive-SharePointFiles.ps1 for the same pattern.
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

Write-Host "=== Archive Reconciliation Check ===" -ForegroundColor Cyan
Write-Host "Config : $ConfigPath"
Write-Host "Report : $ReportPath"
Write-Host ""

# ---------------------------------------------------------------------------
# Source library
# ---------------------------------------------------------------------------
Connect-PnPOnlineAndVerify -Url $cfg.SourceSiteUrl -ClientId $cfg.ClientId -Thumbprint $cfg.Thumbprint -Tenant $cfg.Tenant -Label "source site"

$srcList = Get-PnPList -Identity $cfg.SourceLibrary -Includes RootFolder
$srcRoot = $srcList.RootFolder.ServerRelativeUrl

Write-Phase "Enumerating source files (progress every 5000 or 5s below)..."
$srcScanStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$cutoffDate = (Get-Date).AddYears(-1 * $cfg.ArchiveThresholdYears)
$script:srcSeen = 0
$srcScanGate = New-ProgressGate
$srcItems = Get-PnPListItem -List $srcList -PageSize 500 -Fields "FileLeafRef","FileRef","Modified","File_x0020_Size","FSObjType" |
    ForEach-Object {
        $script:srcSeen++
        if (Test-ProgressGate -Gate $srcScanGate -Count $script:srcSeen -Total -1) {
            Write-Host ("  [$(Get-Timestamp)] ...read {0:N0} items so far ({1:N0}s elapsed)" -f $script:srcSeen, $srcScanStopwatch.Elapsed.TotalSeconds) -ForegroundColor DarkGray
        }
        $_
    } |
    Where-Object { $_.FieldValues.FSObjType -eq 0 }

$srcMap = @{}
foreach ($i in $srcItems) {
    $rel = $i.FieldValues.FileRef -replace [regex]::Escape("$srcRoot/"), ""
    $srcMap[$rel] = [PSCustomObject]@{
        FileRef  = $i.FieldValues.FileRef
        Modified = $i.FieldValues.Modified
        SizeBytes = $i.FieldValues.File_x0020_Size
        Eligible = $i.FieldValues.Modified -lt $cutoffDate
    }
}
Write-Host ("[$(Get-Timestamp)] Source files: {0:N0} (took {1:N0}s)." -f $srcMap.Count, $srcScanStopwatch.Elapsed.TotalSeconds) -ForegroundColor Green

# ---------------------------------------------------------------------------
# By-year file inventory (source library) - last 5 calendar years
# ---------------------------------------------------------------------------
$currentYear = (Get-Date).Year
Write-Host "`nFile inventory by year (source library, all files regardless of archive status):" -ForegroundColor Cyan
for ($y = $currentYear; $y -gt ($currentYear - 5); $y--) {
    $filesInYear = $srcMap.Values | Where-Object { $_.Modified.Year -eq $y }
    $sizeGB = [math]::Round((($filesInYear | Measure-Object -Property SizeBytes -Sum).Sum / 1GB), 2)
    Write-Host ("{0}   {1:N0} files   {2:N2} GB" -f $y, $filesInYear.Count, $sizeGB)
}
$olderSrcFiles = $srcMap.Values | Where-Object { $_.Modified.Year -le ($currentYear - 5) }
$olderSizeGB = [math]::Round((($olderSrcFiles | Measure-Object -Property SizeBytes -Sum).Sum / 1GB), 2)
Write-Host ("Older than {0}   {1:N0} files   {2:N2} GB" -f ($currentYear - 5), $olderSrcFiles.Count, $olderSizeGB)

# ---------------------------------------------------------------------------
# Archive library
# ---------------------------------------------------------------------------
Connect-PnPOnlineAndVerify -Url $cfg.ArchiveSiteUrl -ClientId $cfg.ClientId -Thumbprint $cfg.Thumbprint -Tenant $cfg.Tenant -Label "archive site"

$archList = Get-PnPList -Identity $cfg.ArchiveLibrary -Includes RootFolder -ErrorAction SilentlyContinue
if (-not $archList) {
    Write-Host "[$(Get-Timestamp)] Archive library not found yet - nothing has landed there." -ForegroundColor Red
    return
}
$archRoot = $archList.RootFolder.ServerRelativeUrl

Write-Phase "Enumerating archive files (progress every 5000 or 5s below)..."
$archScanStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$script:archSeen = 0
$archScanGate = New-ProgressGate
$archItems = Get-PnPListItem -List $archList -PageSize 500 -Fields "FileLeafRef","FileRef","FSObjType" |
    ForEach-Object {
        $script:archSeen++
        if (Test-ProgressGate -Gate $archScanGate -Count $script:archSeen -Total -1) {
            Write-Host ("  [$(Get-Timestamp)] ...read {0:N0} items so far ({1:N0}s elapsed)" -f $script:archSeen, $archScanStopwatch.Elapsed.TotalSeconds) -ForegroundColor DarkGray
        }
        $_
    } |
    Where-Object { $_.FieldValues.FSObjType -eq 0 }

$archMap = @{}
foreach ($i in $archItems) {
    $rel = $i.FieldValues.FileRef -replace [regex]::Escape("$archRoot/"), ""
    $archMap[$rel] = $i.FieldValues.FileRef
}
Write-Host ("[$(Get-Timestamp)] Archive files: {0:N0} (took {1:N0}s)." -f $archMap.Count, $archScanStopwatch.Elapsed.TotalSeconds) -ForegroundColor Green

# ---------------------------------------------------------------------------
# Classify
# ---------------------------------------------------------------------------
Write-Phase "Classifying $($archMap.Count + $srcMap.Count) file reference(s)..."
$report = New-Object System.Collections.Generic.List[Object]

foreach ($rel in $archMap.Keys) {
    if ($srcMap.ContainsKey($rel)) {
        $report.Add([PSCustomObject]@{
            RelativePath = $rel
            Status       = "COPIED_NOT_DELETED"
            SourcePath   = $srcMap[$rel].FileRef
            ArchivePath  = $archMap[$rel]
        })
    } else {
        $report.Add([PSCustomObject]@{
            RelativePath = $rel
            Status       = "ARCHIVED_CONFIRMED"
            SourcePath   = ""
            ArchivePath  = $archMap[$rel]
        })
    }
}

foreach ($rel in $srcMap.Keys) {
    if (-not $archMap.ContainsKey($rel)) {
        $report.Add([PSCustomObject]@{
            RelativePath = $rel
            Status       = if ($srcMap[$rel].Eligible) { "NOT_YET_ARCHIVED_ELIGIBLE" } else { "NOT_YET_ARCHIVED_TOO_RECENT" }
            SourcePath   = $srcMap[$rel].FileRef
            ArchivePath  = ""
        })
    }
}

Write-Host "[$(Get-Timestamp)] Classification complete: $($report.Count) row(s)." -ForegroundColor Green
$report | Export-Csv -Path $ReportPath -NoTypeInformation -Force

$summary = $report | Group-Object Status | Select-Object Name, Count
Write-Host "`n=== Summary ===" -ForegroundColor Cyan
$summary | ForEach-Object { Write-Host "$($_.Name): $($_.Count)" }
Write-Host "`nFull report written to: $ReportPath" -ForegroundColor Green
Write-Host "Follow up on any COPIED_NOT_DELETED rows - those are copied but the original was never removed." -ForegroundColor Yellow
