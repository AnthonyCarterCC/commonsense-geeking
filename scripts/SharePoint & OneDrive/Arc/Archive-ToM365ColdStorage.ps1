#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.Sites, Microsoft.Graph.Files
<#
.SYNOPSIS
    Archives files older than a configurable age threshold into Microsoft 365 Archive
    (SharePoint's native cold-storage tier) - the actual equivalent of Exchange
    Online's "Online Archive," rather than moving files to a second site collection.

.DESCRIPTION
    Unlike Archive-SharePointFiles.ps1 (which copies files to a separate archive SITE
    you manage), this script uses Microsoft's built-in file-level archive feature via
    the Microsoft Graph beta API. Archived files stay in place - same URL, same
    permissions, same search/eDiscovery visibility - but move to Microsoft's cheaper
    cold storage tier and stop consuming active SharePoint quota. Users can reactivate
    an archived file at any time (free, may take up to ~24h to rehydrate).

    Per-tenant one-time prerequisites (see ONBOARDING NOTES at the bottom of this file):
      1. Microsoft 365 Archive / file-level archive enabled tenant-wide
         (Set-SPOTenant -AllowFileArchive $true - requires SharePoint/Global Admin,
         SPO Management Shell, cannot be done app-only).
      2. An Entra app registration with Microsoft GRAPH application permission
         Sites.ReadWrite.All (admin-consented) and a certificate for app-only auth.
         This is a DIFFERENT permission system to the SharePoint-specific
         "SharePointApplicationPermissions" used by Archive-SharePointFiles.ps1's app -
         you need Graph API permissions specifically for this script to work.

.NOTES
    Run with -WhatIf first. Nothing is archived until you drop -WhatIf.
    Reactivated files can't be re-archived for ~120 days (Microsoft-imposed cooldown).
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath,

    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Load config
# ---------------------------------------------------------------------------
if (-not (Test-Path $ConfigPath)) {
    throw "Config file not found at $ConfigPath"
}
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json

$cutoffDate = (Get-Date).AddYears(-1 * $cfg.ArchiveThresholdYears)
$logPath    = $cfg.LogPath
$log        = New-Object System.Collections.Generic.List[Object]

function Write-Log {
    param($SiteUrl, $Library, $FileName, $FilePath, $ModifiedDate, $Status, $Detail = "")
    $log.Add([PSCustomObject]@{
        Timestamp    = (Get-Date).ToString("s")
        SiteUrl      = $SiteUrl
        Library      = $Library
        FileName     = $FileName
        FilePath     = $FilePath
        ModifiedDate = $ModifiedDate
        Status       = $Status
        Detail       = $Detail
        WhatIf       = [bool]$WhatIf
    })
}

# ---------------------------------------------------------------------------
# Visibility helpers - see Archive-SharePointFiles.ps1 for the same pattern.
# Every phase and every connection prints a timestamped line so the console
# always shows what stage the run is in, rather than going silent.
# ---------------------------------------------------------------------------
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

function Connect-MgGraphAndVerify {
    # Connects AND proves it with a real round-trip call - Connect-MgGraph
    # alone can "succeed" locally without confirming Graph is reachable.
    param([string]$ClientId, [string]$TenantId, [string]$Thumbprint)
    Write-Phase "Connecting to Microsoft Graph (app-only)..."
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        Connect-MgGraph -ClientId $ClientId -TenantId $TenantId -CertificateThumbprint $Thumbprint -NoWelcome
        $org = Get-MgOrganization -Property DisplayName -ErrorAction Stop | Select-Object -First 1
        Write-Host ("[$(Get-Timestamp)] Connected - '{0}' responded in {1:N1}s." -f $org.DisplayName, $sw.Elapsed.TotalSeconds) -ForegroundColor Green
    } catch {
        Write-Host "[$(Get-Timestamp)] FAILED to connect to Microsoft Graph: $($_.Exception.Message)" -ForegroundColor Red
        throw
    }
}

Write-Host "=== Microsoft 365 Archive (cold storage) run ===" -ForegroundColor Cyan
Write-Host "Threshold : files older than $($cfg.ArchiveThresholdYears) years (before $($cutoffDate.ToShortDateString()))"
Write-Host "Sites     : $($cfg.Sites.Count)"
Write-Host "What-if   : $([bool]$WhatIf)"
Write-Host ""

# ---------------------------------------------------------------------------
# Connect - app-only via certificate (Microsoft Graph PowerShell SDK)
# ---------------------------------------------------------------------------
Connect-MgGraphAndVerify -ClientId $cfg.ClientId -TenantId $cfg.TenantId -Thumbprint $cfg.Thumbprint

$totalArchived = 0
$totalSkipped  = 0
$totalErrors   = 0
$globalYearData = @{}   # accumulates the by-year breakdown across all sites in this run

$siteIndex = 0
$totalSites = $cfg.Sites.Count
foreach ($siteEntry in $cfg.Sites) {
    $siteIndex++
    Write-Phase "Site [$siteIndex/$totalSites]: $($siteEntry.SiteUrl)"

    try {
        # Resolve the site by server-relative path (hostname:path form Graph expects)
        $uri = [Uri]$siteEntry.SiteUrl
        $site = Get-MgSite -SiteId "$($uri.Host):$($uri.AbsolutePath)"
        Write-Host "[$(Get-Timestamp)] Site resolved: $($site.DisplayName)" -ForegroundColor Green
    } catch {
        Write-Host "[$(Get-Timestamp)] Could not resolve site $($siteEntry.SiteUrl) : $($_.Exception.Message)" -ForegroundColor Red
        $totalErrors++
        continue
    }

    $library = if ($siteEntry.Library) { $siteEntry.Library } else { "Documents" }

    try {
        $list = Get-MgSiteList -SiteId $site.Id | Where-Object { $_.DisplayName -eq $library }
        if (-not $list) {
            Write-Host "[$(Get-Timestamp)] Library '$library' not found on this site - skipping." -ForegroundColor Red
            $totalErrors++
            continue
        }
        Write-Host "[$(Get-Timestamp)] Library found: '$library'" -ForegroundColor Green
    } catch {
        Write-Host "[$(Get-Timestamp)] Error fetching library '$library' : $($_.Exception.Message)" -ForegroundColor Red
        $totalErrors++
        continue
    }

    Write-Phase "Reading '$library' (single bulk read - no per-item output until this finishes, that's normal)..."
    $siteScanStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    # Get-MgSiteListItem -All flattens the WHOLE library (all folders), no manual
    # recursion needed - it returns list items the same way SharePoint's own list
    # view does. _FileArchiveStatus is a hidden field that's non-null once archived.
    [array]$items = Get-MgSiteListItem -SiteId $site.Id -ListId $list.Id -All `
        -ExpandProperty "driveItem,fields(`$select=FileLeafRef,FileRef,Modified,FSObjType,_FileArchiveStatus,File_x0020_Size)"

    Write-Host ("[$(Get-Timestamp)] Read {0:N0} item(s) from '{1}' in {2:N0}s." -f $items.Count, $library, $siteScanStopwatch.Elapsed.TotalSeconds) -ForegroundColor Green

    $allSiteFiles = $items | Where-Object { $_.Fields.AdditionalProperties['FSObjType'] -eq "0" }

    $eligible = $items | Where-Object {
        $_.Fields.AdditionalProperties['FSObjType'] -eq "0" -and                       # files only
        [datetime]$_.Fields.AdditionalProperties['Modified'] -lt $cutoffDate -and       # older than threshold
        -not $_.Fields.AdditionalProperties['_FileArchiveStatus']                       # not already archived
    }

    Write-Host "[$(Get-Timestamp)] Found $($eligible.Count) eligible file(s)." -ForegroundColor Cyan

    # -----------------------------------------------------------------------
    # By-year file inventory for this site - last 5 calendar years
    # -----------------------------------------------------------------------
    $currentYear = (Get-Date).Year
    Write-Host "File inventory by year ('$library', all files regardless of archive status):" -ForegroundColor Cyan
    for ($y = $currentYear; $y -gt ($currentYear - 5); $y--) {
        $filesInYear = $allSiteFiles | Where-Object { ([datetime]$_.Fields.AdditionalProperties['Modified']).Year -eq $y }
        $sizeBytes = ($filesInYear | ForEach-Object { [int64]$_.Fields.AdditionalProperties['File_x0020_Size'] } | Measure-Object -Sum).Sum
        $sizeGB = [math]::Round(($sizeBytes / 1GB), 2)
        Write-Host ("{0}   {1:N0} files   {2:N2} GB" -f $y, $filesInYear.Count, $sizeGB)

        if (-not $globalYearData.ContainsKey($y)) { $globalYearData[$y] = @{ Count = 0; SizeBytes = 0 } }
        $globalYearData[$y].Count += $filesInYear.Count
        $globalYearData[$y].SizeBytes += $sizeBytes
    }
    $olderFiles = $allSiteFiles | Where-Object { ([datetime]$_.Fields.AdditionalProperties['Modified']).Year -le ($currentYear - 5) }
    $olderSizeBytes = ($olderFiles | ForEach-Object { [int64]$_.Fields.AdditionalProperties['File_x0020_Size'] } | Measure-Object -Sum).Sum
    Write-Host ("Older than {0}   {1:N0} files   {2:N2} GB" -f ($currentYear - 5), $olderFiles.Count, [math]::Round(($olderSizeBytes / 1GB), 2))
    if (-not $globalYearData.ContainsKey("Older")) { $globalYearData["Older"] = @{ Count = 0; SizeBytes = 0 } }
    $globalYearData["Older"].Count += $olderFiles.Count
    $globalYearData["Older"].SizeBytes += $olderSizeBytes

    $archiveIndex = 0
    $totalEligible = $eligible.Count
    $archiveGate = New-ProgressGate
    if ($totalEligible -gt 0) { Write-Phase "Archiving $totalEligible file(s) in '$library' (progress every 5000 or 5s below)..." }
    foreach ($item in $eligible) {
        $archiveIndex++
        $fileName = $item.Fields.AdditionalProperties['FileLeafRef']
        $filePath = $item.Fields.AdditionalProperties['FileRef']
        $modified = $item.Fields.AdditionalProperties['Modified']
        $driveItemId = $item.DriveItem.Id

        if ($WhatIf) {
            if (Test-ProgressGate -Gate $archiveGate -Count $archiveIndex -Total $totalEligible) {
                Write-Host "[$(Get-Timestamp)] [$archiveIndex/$totalEligible] [WHATIF] Would archive: $filePath" -ForegroundColor Magenta
            }
            Write-Log -SiteUrl $siteEntry.SiteUrl -Library $library -FileName $fileName -FilePath $filePath -ModifiedDate $modified -Status "WHATIF-SKIPPED"
            $totalSkipped++
            continue
        }

        try {
            $archiveUri = "https://graph.microsoft.com/beta/sites/$($site.Id)/drive/items/$driveItemId/archive"
            Invoke-MgGraphRequest -Method POST -Uri $archiveUri -OutputType PSObject | Out-Null
            if (Test-ProgressGate -Gate $archiveGate -Count $archiveIndex -Total $totalEligible) {
                Write-Host "[$(Get-Timestamp)] [$archiveIndex/$totalEligible] Archived: $fileName" -ForegroundColor Green
            }
            Write-Log -SiteUrl $siteEntry.SiteUrl -Library $library -FileName $fileName -FilePath $filePath -ModifiedDate $modified -Status "ARCHIVED"
            $totalArchived++
        } catch {
            Write-Host "[$(Get-Timestamp)] [$archiveIndex/$totalEligible] Error archiving $fileName : $($_.Exception.Message)" -ForegroundColor Red
            Write-Log -SiteUrl $siteEntry.SiteUrl -Library $library -FileName $fileName -FilePath $filePath -ModifiedDate $modified -Status "ERROR" -Detail $_.Exception.Message
            $totalErrors++
        }
    }
}

# ---------------------------------------------------------------------------
# Write log + summary
# ---------------------------------------------------------------------------
$log | Export-Csv -Path $logPath -NoTypeInformation -Append -Force

Write-Host "`n=== Summary ===" -ForegroundColor Cyan
Write-Host "Archived        : $totalArchived"
Write-Host "Skipped (whatif): $totalSkipped"
Write-Host "Errors          : $totalErrors"
Write-Host "Log written to  : $logPath"

Write-Host "`nFile inventory by year (all sites combined, all files regardless of archive status):" -ForegroundColor Cyan
$currentYear = (Get-Date).Year
for ($y = $currentYear; $y -gt ($currentYear - 5); $y--) {
    $d = if ($globalYearData.ContainsKey($y)) { $globalYearData[$y] } else { @{ Count = 0; SizeBytes = 0 } }
    Write-Host ("{0}   {1:N0} files   {2:N2} GB" -f $y, $d.Count, [math]::Round(($d.SizeBytes / 1GB), 2))
}
$dOlder = if ($globalYearData.ContainsKey("Older")) { $globalYearData["Older"] } else { @{ Count = 0; SizeBytes = 0 } }
Write-Host ("Older than {0}   {1:N0} files   {2:N2} GB" -f ($currentYear - 5), $dOlder.Count, [math]::Round(($dOlder.SizeBytes / 1GB), 2))

Disconnect-MgGraph | Out-Null

<#
=====================================================================
ONBOARDING NOTES - one-time steps per NEW client tenant before this
script can run there
=====================================================================

1. INSTALL MODULES (once per machine)
   Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Sites, Microsoft.Graph.Files -Scope CurrentUser -Force

2. ENABLE MICROSOFT 365 ARCHIVE ON THE CLIENT TENANT (interactive, one-time)
   This CANNOT be done app-only - requires a SharePoint/Global Admin running
   SPO Management Shell interactively against the client tenant:

     Connect-SPOService -Url https://CLIENTTENANT-admin.sharepoint.com
     Set-SPOTenant -AllowFileArchive $true
     Set-SPOTenant -AllowFileArchiveOnNewSitesByDefault $true   # optional

   Confirm it took effect:
     Get-SPOTenant | Select-Object AllowFileArchive

3. REGISTER (OR REUSE) AN APP WITH GRAPH PERMISSIONS
   This is a DIFFERENT permission model to the SharePointApplicationPermissions
   used for Archive-SharePointFiles.ps1 - you need an actual Microsoft Graph
   APPLICATION permission, not the legacy SharePoint app-only permission:

     Register-PnPEntraIDApp -ApplicationName "M365-Archive-Automation" `
         -Tenant "CLIENTTENANT.onmicrosoft.com" `
         -GraphApplicationPermissions "Sites.ReadWrite.All"

   Then grant admin consent in the Entra portal (App registrations > API
   permissions > Grant admin consent), same propagation-delay caveat applies
   (5-30 min) as with the SharePoint app.

   You CAN reuse the existing SPO-Archive-Automation cert/app if you add the
   Graph "Sites.ReadWrite.All" application permission to that same app
   registration and re-consent, rather than creating a second app - simpler
   for a client that already has Archive-SharePointFiles.ps1 set up.

4. BUILD A CONFIG FILE per client (see config-m365archive.template.json)
   List every site + library you want covered - this script does NOT
   auto-discover every site in the tenant, by design, so an MSP always
   knows exactly what's in scope for a given client engagement.

5. TEST WITH -WhatIf FIRST
     .\Archive-ToM365ColdStorage.ps1 -ConfigPath ".\config-m365archive.json" -WhatIf

   Review the log, then rerun without -WhatIf.

MULTI-CLIENT / MSP SCALING NOTE:
Each client tenant needs its own app registration + cert (Entra apps are
tenant-bound) unless you set up a proper multi-tenant Entra app + use GDAP
(Granular Delegated Admin Privileges) via Partner Center, which lets one app
registration act across all your managed client tenants without a
per-client cert. That's a bigger one-time investment but removes the
per-client cert/app setup step entirely - worth it once you're past a
handful of clients using this script regularly.
#>
