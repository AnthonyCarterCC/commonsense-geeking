<#
.SYNOPSIS
    Archives stale files from a source SharePoint library to a destination SharePoint library.

.DESCRIPTION
    Enumerates files in a source SharePoint Online document library, identifies files whose
    "Modified" date is older than a configurable threshold, and copies them to a destination
    site/library (typically an "archive" site). Source files are only deleted after a copy is
    verified, and only when run in -LiveRun mode.

    Designed to be run quarterly, either manually or via Azure Automation / scheduled task.

    SAFETY MODEL:
      1. Dry run (default) -> produces a CSV of candidate files only. Nothing is touched.
      2. Live run (-LiveRun) -> copies files, verifies the copy, then either:
            - deletes the source file immediately (-DeleteAfterCopy), or
            - moves the source file into a "_PendingDelete" folder for a manual/automated
              cleanup pass later (default behaviour if -DeleteAfterCopy is not specified).

.NOTES
    Requires: PnP.PowerShell module (NOT the deprecated SharePointPnPPowerShellOnline)
    Auth: App-only auth via Azure AD App Registration + certificate (recommended for
          unattended/scheduled runs - no MFA prompts, no stored user credentials).

    Install module:
        Install-Module -Name PnP.PowerShell -Scope CurrentUser

    Register an app + cert (one-time per tenant), see companion file:
        Setup-AppRegistration.md

.PARAMETER SourceSiteUrl
    Full URL of the source SharePoint site, e.g. https://contoso.sharepoint.com/sites/Finance

.PARAMETER SourceLibrary
    Display name of the source document library, e.g. "Documents" or "Old Projects"

.PARAMETER DestinationSiteUrl
    Full URL of the destination (archive) SharePoint site.

.PARAMETER DestinationLibrary
    Display name of the destination document library.

.PARAMETER MonthsInactiveThreshold
    Files not modified within this many months are considered "stale" candidates.

.PARAMETER ClientId
    Azure AD App Registration (Entra ID) client/application ID used for app-only auth.

.PARAMETER Tenant
    Tenant name, e.g. contoso.onmicrosoft.com

.PARAMETER CertificatePath
    Path to the .pfx certificate file used for app-only auth.

.PARAMETER CertificatePassword
    SecureString password for the .pfx. Omit if cert has no password (not recommended).

.PARAMETER LiveRun
    If specified, actually performs the copy (and optionally delete). If omitted, the script
    runs in dry-run mode: it reports what WOULD be moved and writes a CSV, but touches nothing.

.PARAMETER DeleteAfterCopy
    Only relevant with -LiveRun. If specified, deletes the source file immediately after a
    verified copy. If omitted, source files are moved to a "_PendingDelete" subfolder instead
    of being deleted outright, giving you a buffer period before permanent removal.

.PARAMETER ExcludeFolders
    Array of folder name fragments to skip entirely (e.g. "DoNotArchive", "Active").

.PARAMETER OutputDirectory
    Where CSV logs and run summaries are written. Defaults to .\Logs

.EXAMPLE
    # Dry run - safe, default. Produces CSV only.
    .\Archive-StaleSharePointFiles.ps1 `
        -SourceSiteUrl "https://contoso.sharepoint.com/sites/Finance" `
        -SourceLibrary "Documents" `
        -DestinationSiteUrl "https://contoso.sharepoint.com/sites/FinanceArchive" `
        -DestinationLibrary "Documents" `
        -MonthsInactiveThreshold 24 `
        -ClientId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -Tenant "contoso.onmicrosoft.com" `
        -CertificatePath "C:\certs\contoso-archiver.pfx"

.EXAMPLE
    # Live run - copies files, moves originals to _PendingDelete (safer default)
    .\Archive-StaleSharePointFiles.ps1 `
        -SourceSiteUrl "https://contoso.sharepoint.com/sites/Finance" `
        -SourceLibrary "Documents" `
        -DestinationSiteUrl "https://contoso.sharepoint.com/sites/FinanceArchive" `
        -DestinationLibrary "Documents" `
        -MonthsInactiveThreshold 24 `
        -ClientId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -Tenant "contoso.onmicrosoft.com" `
        -CertificatePath "C:\certs\contoso-archiver.pfx" `
        -LiveRun

.EXAMPLE
    # Live run - copies files AND deletes originals immediately (no buffer folder)
    .\Archive-StaleSharePointFiles.ps1 `
        -SourceSiteUrl "https://contoso.sharepoint.com/sites/Finance" `
        -SourceLibrary "Documents" `
        -DestinationSiteUrl "https://contoso.sharepoint.com/sites/FinanceArchive" `
        -DestinationLibrary "Documents" `
        -MonthsInactiveThreshold 24 `
        -ClientId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -Tenant "contoso.onmicrosoft.com" `
        -CertificatePath "C:\certs\contoso-archiver.pfx" `
        -LiveRun -DeleteAfterCopy
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourceSiteUrl,

    [Parameter(Mandatory = $true)]
    [string]$SourceLibrary,

    [Parameter(Mandatory = $true)]
    [string]$DestinationSiteUrl,

    [Parameter(Mandatory = $true)]
    [string]$DestinationLibrary,

    [Parameter(Mandatory = $false)]
    [int]$MonthsInactiveThreshold = 24,

    [Parameter(Mandatory = $true)]
    [string]$ClientId,

    [Parameter(Mandatory = $true)]
    [string]$Tenant,

    [Parameter(Mandatory = $true)]
    [string]$CertificatePath,

    [Parameter(Mandatory = $false)]
    [System.Security.SecureString]$CertificatePassword,

    [Parameter(Mandatory = $false)]
    [switch]$LiveRun,

    [Parameter(Mandatory = $false)]
    [switch]$DeleteAfterCopy,

    [Parameter(Mandatory = $false)]
    [string[]]$ExcludeFolders = @("_PendingDelete", "DoNotArchive"),

    [Parameter(Mandatory = $false)]
    [string]$OutputDirectory = ".\Logs"
)

# ----------------------------------------------------------------------------
# Setup
# ----------------------------------------------------------------------------

$ErrorActionPreference = "Stop"
$ScriptStartTime = Get-Date
$RunMode = if ($LiveRun) { "LIVE" } else { "DRY-RUN" }

if (-not (Test-Path $OutputDirectory)) {
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
}

$Timestamp      = Get-Date -Format "yyyyMMdd-HHmmss"
$CsvPath        = Join-Path $OutputDirectory "ArchiveCandidates-$Timestamp.csv"
$LogPath        = Join-Path $OutputDirectory "ArchiveRun-$Timestamp.log"
$ErrorCsvPath   = Join-Path $OutputDirectory "ArchiveErrors-$Timestamp.csv"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    Write-Host $line
    Add-Content -Path $LogPath -Value $line
}

Write-Log "===================================================="
Write-Log "SharePoint Stale File Archiver - Mode: $RunMode"
Write-Log "Source:      $SourceSiteUrl  [$SourceLibrary]"
Write-Log "Destination: $DestinationSiteUrl  [$DestinationLibrary]"
Write-Log "Threshold:   files not modified in $MonthsInactiveThreshold+ months"
Write-Log "DeleteAfterCopy: $($DeleteAfterCopy.IsPresent)"
Write-Log "===================================================="

if (-not $LiveRun) {
    Write-Log "DRY RUN MODE: No files will be copied, moved, or deleted. CSV report only." "WARN"
}

# ----------------------------------------------------------------------------
# Module check
# ----------------------------------------------------------------------------

if (-not (Get-Module -ListAvailable -Name PnP.PowerShell)) {
    Write-Log "PnP.PowerShell module not found. Install with: Install-Module PnP.PowerShell -Scope CurrentUser" "ERROR"
    throw "Missing required module: PnP.PowerShell"
}
Import-Module PnP.PowerShell -ErrorAction Stop

# ----------------------------------------------------------------------------
# Connect to source
# ----------------------------------------------------------------------------

Write-Log "Connecting to source site..."
try {
    $connectParams = @{
        Url           = $SourceSiteUrl
        ClientId      = $ClientId
        Tenant        = $Tenant
        CertificatePath = $CertificatePath
    }
    if ($CertificatePassword) { $connectParams["CertificatePassword"] = $CertificatePassword }

    Connect-PnPOnline @connectParams
    $SourceConnection = Get-PnPConnection
    Write-Log "Connected to source: $SourceSiteUrl"
}
catch {
    Write-Log "Failed to connect to source site: $($_.Exception.Message)" "ERROR"
    throw
}

# ----------------------------------------------------------------------------
# Enumerate candidate files from source
# ----------------------------------------------------------------------------

$CutoffDate = (Get-Date).AddMonths(-$MonthsInactiveThreshold)
Write-Log "Cutoff date for staleness: $($CutoffDate.ToString('yyyy-MM-dd'))"

Write-Log "Enumerating files in '$SourceLibrary' (this can take a while for large libraries)..."

# Get-PnPListItem with PageSize handles large lists without throttling as hard as a naive query.
# Folders are list items with FSObjType = 1; files are FSObjType = 0.
$allItems = Get-PnPListItem -List $SourceLibrary -PageSize 2000 -Fields "FileLeafRef","FileRef","FSObjType","Modified","File_x0020_Size","Author" -ScriptBlock {
    Param($items) Write-Log ("  ...retrieved {0} items so far" -f $items.Count)
}

$files = $allItems | Where-Object { $_["FSObjType"] -eq 0 }
Write-Log "Total files found: $($files.Count)"

# Filter: exclude anything in excluded folder paths
$candidates = foreach ($item in $files) {
    $serverRelativeUrl = $item["FileRef"]
    $excluded = $false
    foreach ($ex in $ExcludeFolders) {
        if ($serverRelativeUrl -match [regex]::Escape($ex)) { $excluded = $true; break }
    }
    if ($excluded) { continue }

    $modified = $item["Modified"]
    if ($modified -lt $CutoffDate) {
        [PSCustomObject]@{
            FileName       = $item["FileLeafRef"]
            ServerRelUrl   = $serverRelativeUrl
            Modified       = $modified
            SizeBytes      = $item["File_x0020_Size"]
            Author         = $item["Author"].LookupValue
            Status         = "Pending"
            ErrorMessage   = ""
        }
    }
}

Write-Log "Stale candidates (older than $MonthsInactiveThreshold months): $($candidates.Count)"

if ($candidates.Count -eq 0) {
    Write-Log "No stale files found. Nothing to do. Exiting."
    Disconnect-PnPOnline
    return
}

$totalSizeGB = [math]::Round((($candidates | Measure-Object -Property SizeBytes -Sum).Sum / 1GB), 2)
Write-Log "Total size of candidates: $totalSizeGB GB"

# Always write the candidate CSV first - this is your audit trail regardless of mode.
$candidates | Select-Object FileName, ServerRelUrl, Modified, SizeBytes, Author |
    Export-Csv -Path $CsvPath -NoTypeInformation
Write-Log "Candidate list written to: $CsvPath"

if (-not $LiveRun) {
    Write-Log "DRY RUN complete. Review $CsvPath, then re-run with -LiveRun to execute." "WARN"
    Disconnect-PnPOnline
    return
}

# ----------------------------------------------------------------------------
# LIVE RUN: connect to destination
# ----------------------------------------------------------------------------

Write-Log "Connecting to destination site..."
try {
    $destConnectParams = @{
        Url             = $DestinationSiteUrl
        ClientId        = $ClientId
        Tenant          = $Tenant
        CertificatePath = $CertificatePath
    }
    if ($CertificatePassword) { $destConnectParams["CertificatePassword"] = $CertificatePassword }

    $DestConnection = Connect-PnPOnline @destConnectParams -ReturnConnection
    Write-Log "Connected to destination: $DestinationSiteUrl"
}
catch {
    Write-Log "Failed to connect to destination site: $($_.Exception.Message)" "ERROR"
    throw
}

# ----------------------------------------------------------------------------
# Copy each candidate, verify, then handle source per -DeleteAfterCopy
# ----------------------------------------------------------------------------

$successCount = 0
$failCount    = 0
$errors       = @()

# Reconnect to source for per-file operations (Copy-PnPFile needs the source connection context
# for the -SourceUrl parameter approach; we switch connection context as needed below).
Connect-PnPOnline -Url $SourceSiteUrl -ClientId $ClientId -Tenant $Tenant -CertificatePath $CertificatePath @(if($CertificatePassword){@{CertificatePassword=$CertificatePassword}})

$i = 0
foreach ($file in $candidates) {
    $i++
    Write-Log ("[{0}/{1}] Processing: {2}" -f $i, $candidates.Count, $file.ServerRelUrl)

    try {
        # Build destination folder path mirroring source folder structure under the library root.
        # Strip the source library's root path, prepend the destination library root.
        $relativePath = $file.ServerRelUrl -replace "^/sites/[^/]+/[^/]+/", ""
        $destFolderPath = (Split-Path $relativePath -Parent)

        # Copy-PnPFile supports cross-site copy when given a full source URL and a target library/folder.
        # -Force overwrites if a same-named file already exists at destination (rare on first run,
        # common if a previous run partially failed).
        Copy-PnPFile -SourceUrl $file.ServerRelUrl `
                      -TargetUrl "$DestinationLibrary/$destFolderPath" `
                      -OverwriteIfAlreadyExists `
                      -Connection $DestConnection `
                      -ErrorAction Stop

        # --- Verification step ---
        # Confirm the file now exists at the destination before touching the source.
        $destCheckPath = "$DestinationLibrary/$destFolderPath/$($file.FileName)" -replace "//","/"
        $destItem = Get-PnPFile -Url $destCheckPath -Connection $DestConnection -AsListItem -ErrorAction SilentlyContinue

        if (-not $destItem) {
            throw "Post-copy verification failed: file not found at destination ($destCheckPath)"
        }

        # Verification passed - now deal with the source copy.
        if ($DeleteAfterCopy) {
            Remove-PnPFile -ServerRelativeUrl $file.ServerRelUrl -Force -Recycle -ErrorAction Stop
            Write-Log "  Copied + deleted (recycled) source: $($file.FileName)"
        }
        else {
            # Move source into a _PendingDelete buffer folder instead of deleting outright.
            $pendingFolder = (Split-Path $file.ServerRelUrl -Parent) + "/_PendingDelete"
            # Ensure the pending-delete folder exists (idempotent - PnP won't error if it already does
            # in most versions, but we guard anyway).
            try {
                Resolve-PnPFolder -SiteRelativePath ($pendingFolder -replace "^/sites/[^/]+/","") -ErrorAction SilentlyContinue | Out-Null
            } catch {}

            Move-PnPFile -SourceUrl $file.ServerRelUrl -TargetUrl $pendingFolder -OverwriteIfAlreadyExists -Force -ErrorAction Stop
            Write-Log "  Copied + moved source to _PendingDelete: $($file.FileName)"
        }

        $file.Status = "Success"
        $successCount++
    }
    catch {
        $file.Status = "Failed"
        $file.ErrorMessage = $_.Exception.Message
        $failCount++
        $errors += $file
        Write-Log "  FAILED: $($file.FileName) - $($_.Exception.Message)" "ERROR"
    }
}

# ----------------------------------------------------------------------------
# Wrap up
# ----------------------------------------------------------------------------

$candidates | Select-Object FileName, ServerRelUrl, Modified, SizeBytes, Author, Status, ErrorMessage |
    Export-Csv -Path $CsvPath -NoTypeInformation -Force

if ($errors.Count -gt 0) {
    $errors | Export-Csv -Path $ErrorCsvPath -NoTypeInformation
    Write-Log "Errors written to: $ErrorCsvPath" "WARN"
}

$duration = (Get-Date) - $ScriptStartTime
Write-Log "===================================================="
Write-Log "RUN COMPLETE - Mode: $RunMode"
Write-Log "Succeeded: $successCount | Failed: $failCount | Total candidates: $($candidates.Count)"
Write-Log "Duration: $($duration.ToString('hh\:mm\:ss'))"
Write-Log "Full report: $CsvPath"
Write-Log "===================================================="

Disconnect-PnPOnline
