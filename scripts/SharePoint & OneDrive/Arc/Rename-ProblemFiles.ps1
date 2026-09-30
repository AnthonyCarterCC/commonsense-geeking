#Requires -Modules PnP.PowerShell
<#
.SYNOPSIS
    Finds and renames files/folders in a SharePoint library whose names contain
    characters known to break Copy-PnPFile's cross-site copy-job API, or other
    SharePoint-discouraged naming patterns.

.DESCRIPTION
    Targets exactly the patterns confirmed to cause problems in this project:
      - "#" and "%" - Microsoft's own guidance flags these as technically
        allowed but unreliable across sync/API/migration scenarios. "#" is
        the confirmed cause of the Digital site's 70 copy failures (SharePoint's
        copy-job API treats it as a URL fragment delimiter and truncates the path).
      - Leading/trailing whitespace on the name.
      - Trailing period(s) - SharePoint disallows names ending in a period.
      - Runs of 2+ consecutive periods (e.g. "..") - collapsed to a single "-".

    Safe by default: run with -WhatIf first (or no switch at all - WhatIf is
    the default) to see what WOULD be renamed, with no changes made. Add
    -Execute to actually perform the renames.

    Reuses one of the existing per-site config.json files for the site URL,
    library name, and app credentials - no new config needed.

.EXAMPLE
    .\Rename-ProblemFiles.ps1 -ConfigPath .\config-digital.json
    # Dry run - lists what would be renamed, changes nothing.

.EXAMPLE
    .\Rename-ProblemFiles.ps1 -ConfigPath .\config-digital.json -Execute
    # Actually renames the flagged files/folders.

.NOTES
    Renames deepest paths first (children before parent folders) so that
    renaming a folder never invalidates a path this script already captured
    for one of its children.

    Run this against the SOURCE site (same config the main archive script
    uses) - the point is to clean up names in place before they're archived,
    or to unblock ones that already failed to copy for this reason.
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

$logPath = Join-Path (Split-Path $ConfigPath -Parent) "rename-log-$([System.IO.Path]::GetFileNameWithoutExtension($ConfigPath)).csv"
$log = New-Object System.Collections.Generic.List[Object]

function Write-Log {
    param($OriginalPath, $NewName, $Type, $Status, $Detail = "")
    $log.Add([PSCustomObject]@{
        Timestamp    = (Get-Date).ToString("s")
        OriginalPath = $OriginalPath
        NewName      = $NewName
        Type         = $Type
        Status       = $Status
        Detail       = $Detail
        Execute      = [bool]$Execute
    })
}

function Get-SanitizedName {
    param([string]$Name)
    $new = $Name.Trim()
    $new = $new -replace '[#%]', ''
    $new = $new -replace '\.{2,}', '-'
    $new = $new.TrimEnd('.')
    $new = $new.Trim()
    if ([string]::IsNullOrWhiteSpace($new)) { $new = "renamed-item" }
    return $new
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

Write-Host "=== Problem-Character Rename Scan ===" -ForegroundColor Cyan
Write-Host "Site    : $($cfg.SourceSiteUrl)"
Write-Host "Library : $($cfg.SourceLibrary)"
Write-Host "Mode    : $(if ($Execute) { 'EXECUTE (will rename)' } else { 'WhatIf (dry run - nothing will change)' })"
Write-Host ""

Connect-PnPOnlineAndVerify -Url $cfg.SourceSiteUrl -ClientId $cfg.ClientId -Thumbprint $cfg.Thumbprint -Tenant $cfg.Tenant -Label "source site"

$list = Get-PnPList -Identity $cfg.SourceLibrary -Includes RootFolder
Write-Phase "Scanning '$($cfg.SourceLibrary)' for problem names (files and folders, progress every 5000 or 5s below)..."
$scanStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$script:scanSeen = 0
$scanGate = New-ProgressGate

$items = Get-PnPListItem -List $list -PageSize 500 -Fields "FileLeafRef","FileRef","FSObjType" |
    ForEach-Object {
        $script:scanSeen++
        if (Test-ProgressGate -Gate $scanGate -Count $script:scanSeen -Total -1) {
            Write-Host ("  [$(Get-Timestamp)] ...read {0:N0} items so far ({1:N0}s elapsed)" -f $script:scanSeen, $scanStopwatch.Elapsed.TotalSeconds) -ForegroundColor DarkGray
        }
        $_
    }

Write-Host ("[$(Get-Timestamp)] Scan complete: {0:N0} items read in {1:N0}s." -f $script:scanSeen, $scanStopwatch.Elapsed.TotalSeconds) -ForegroundColor Green

$problems = foreach ($item in $items) {
    $leaf = $item.FieldValues.FileLeafRef
    $sanitized = Get-SanitizedName $leaf
    if ($sanitized -ne $leaf) {
        [PSCustomObject]@{
            FileRef   = $item.FieldValues.FileRef
            Leaf      = $leaf
            Sanitized = $sanitized
            IsFolder  = ($item.FieldValues.FSObjType -eq 1)
            Depth     = ($item.FieldValues.FileRef -split '/').Count
        }
    }
}

if (-not $problems) {
    Write-Host "No problem names found." -ForegroundColor Green
    return
}

Write-Host "[$(Get-Timestamp)] Found $($problems.Count) item(s) with problem names." -ForegroundColor Cyan
Write-Host ""

# Rename deepest paths first so a parent-folder rename never invalidates a
# path already captured for one of its children.
$problems = $problems | Sort-Object Depth -Descending

# Track sibling names per parent folder (as-renamed) to avoid collisions.
$siblingNames = @{}

$renameIndex = 0
$totalProblems = $problems.Count
$renameGate = New-ProgressGate
Write-Phase "$(if ($Execute) { 'Renaming' } else { 'Previewing rename of' }) $totalProblems item(s) (progress every 5000 or 5s below)..."
foreach ($p in $problems) {
    $renameIndex++
    $parent = ($p.FileRef).Substring(0, $p.FileRef.Length - $p.Leaf.Length - 1)

    if (-not $siblingNames.ContainsKey($parent)) {
        $siblingNames[$parent] = @{}
    }

    $candidate = $p.Sanitized
    $suffix = 1
    while ($siblingNames[$parent].ContainsKey($candidate.ToLower())) {
        $suffix++
        $candidate = "$($p.Sanitized) ($suffix)"
    }
    $siblingNames[$parent][$candidate.ToLower()] = $true

    $type = if ($p.IsFolder) { "Folder" } else { "File" }

    if (-not $Execute) {
        if (Test-ProgressGate -Gate $renameGate -Count $renameIndex -Total $totalProblems) {
            Write-Host "[$(Get-Timestamp)] [$renameIndex/$totalProblems] [WHATIF] Would rename ($type): '$($p.Leaf)' -> '$candidate'" -ForegroundColor Magenta
        }
        Write-Log -OriginalPath $p.FileRef -NewName $candidate -Type $type -Status "WHATIF-SKIPPED"
        continue
    }

    try {
        if ($p.IsFolder) {
            # Rename-PnPFolder has worked reliably for folders, including
            # names containing '#' - no change needed here.
            Rename-PnPFolder -Folder $p.FileRef -TargetFolderName $candidate
        } else {
            # Rename-PnPFile's path resolution is unreliable when the source
            # name contains '%' (manually pre-escaping it as %25 was tried
            # and made things worse - it just looked for a literal "%25" in
            # the path, which doesn't exist either). Trying Move-PnPFile
            # instead (moving to the same parent folder under the new name) -
            # it goes through a different code path and may handle '%'
            # correctly where Rename-PnPFile does not.
            $targetUrl = "$parent/$candidate"
            Move-PnPFile -SourceUrl $p.FileRef -TargetUrl $targetUrl -Force -OverwriteIfAlreadyExists
        }
        if (Test-ProgressGate -Gate $renameGate -Count $renameIndex -Total $totalProblems) {
            Write-Host "[$(Get-Timestamp)] [$renameIndex/$totalProblems] Renamed ($type): '$($p.Leaf)' -> '$candidate'" -ForegroundColor Green
        }
        Write-Log -OriginalPath $p.FileRef -NewName $candidate -Type $type -Status "RENAMED"
    } catch {
        Write-Host "[$(Get-Timestamp)] [$renameIndex/$totalProblems] Error renaming '$($p.Leaf)' : $($_.Exception.Message)" -ForegroundColor Red
        Write-Log -OriginalPath $p.FileRef -NewName $candidate -Type $type -Status "ERROR" -Detail $_.Exception.Message
    }
}

$log | Export-Csv -Path $logPath -NoTypeInformation -Force

Write-Host "`n=== Summary ===" -ForegroundColor Cyan
Write-Host "Problem names found : $($problems.Count)"
Write-Host "Mode                : $(if ($Execute) { 'Executed' } else { 'Dry run only - nothing changed' })"
Write-Host "Log written to      : $logPath"
if (-not $Execute) {
    Write-Host "`nRerun with -Execute to actually apply these renames." -ForegroundColor Yellow
}
