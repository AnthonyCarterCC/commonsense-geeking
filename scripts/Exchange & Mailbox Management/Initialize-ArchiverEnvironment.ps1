<#
.SYNOPSIS
    Bootstraps dependencies and establishes a SharePoint connection for the archiver toolkit.

.DESCRIPTION
    Run this first, before Archive-StaleSharePointFiles.ps1 or Run-QuarterlyArchive.ps1.

    What it does:
      1. Checks for PowerShell 7+ (warns if not, but does not install it - assumed present).
      2. Checks for the PnP.PowerShell module; installs it if missing (or offers to update
         if an old version is present).
      3. Prompts interactively for tenant/site connection details (site URL, App/Client ID,
         Tenant ID, certificate path + password).
      4. Connects using PnP.PowerShell to confirm everything works.
      5. Offers to save the entered details as a new entry in Clients.json, so this prompt
         doesn't need repeating next quarter for the same client.

    This script does NOT create the Azure AD app registration or certificate - that's a
    one-time manual step, see Setup-AppRegistration.md. This script assumes that's already
    done and you just need to wire up the connection.

.PARAMETER ConfigPath
    Path to Clients.json. Defaults to .\Clients.json (created if it doesn't exist and you
    choose to save).

.EXAMPLE
    .\Initialize-ArchiverEnvironment.ps1

.EXAMPLE
    .\Initialize-ArchiverEnvironment.ps1 -ConfigPath "C:\SPArchiver\Clients.json"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = ".\Clients.json"
)

$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "== $Message ==" -ForegroundColor Cyan
}

function Write-Ok   { param([string]$m) Write-Host "  [OK] $m" -ForegroundColor Green }
function Write-Warn2 { param([string]$m) Write-Host "  [!]  $m" -ForegroundColor Yellow }
function Write-Err2  { param([string]$m) Write-Host "  [X]  $m" -ForegroundColor Red }

# ----------------------------------------------------------------------------
# 1. PowerShell version check (informational only - not installing PS7 here)
# ----------------------------------------------------------------------------

Write-Step "Checking PowerShell version"

if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Warn2 "Running on PowerShell $($PSVersionTable.PSVersion). PnP.PowerShell requires PowerShell 7+."
    Write-Warn2 "This script assumes PS7 is already installed - re-launch this script from a 'pwsh' session."
    $continue = Read-Host "Continue anyway? (y/N)"
    if ($continue -notmatch '^[Yy]') {
        throw "Aborted - please re-run from PowerShell 7 (pwsh)."
    }
}
else {
    Write-Ok "PowerShell $($PSVersionTable.PSVersion) detected."
}

# ----------------------------------------------------------------------------
# 2. PnP.PowerShell module - install/update as needed
# ----------------------------------------------------------------------------

Write-Step "Checking PnP.PowerShell module"

$minVersion = [version]"2.2.0"
$installed = Get-Module -ListAvailable -Name PnP.PowerShell |
    Sort-Object Version -Descending | Select-Object -First 1

if (-not $installed) {
    Write-Warn2 "PnP.PowerShell not found. Installing for current user..."
    try {
        Install-Module -Name PnP.PowerShell -Scope CurrentUser -Force -AllowClobber
        Write-Ok "PnP.PowerShell installed."
    }
    catch {
        Write-Err2 "Failed to install PnP.PowerShell: $($_.Exception.Message)"
        throw
    }
}
elseif ($installed.Version -lt $minVersion) {
    Write-Warn2 "PnP.PowerShell $($installed.Version) found, but is older than recommended ($minVersion)."
    $update = Read-Host "Update to latest now? (Y/n)"
    if ($update -notmatch '^[Nn]') {
        Install-Module -Name PnP.PowerShell -Scope CurrentUser -Force -AllowClobber
        Write-Ok "PnP.PowerShell updated."
    }
}
else {
    Write-Ok "PnP.PowerShell $($installed.Version) already installed."
}

Import-Module PnP.PowerShell -ErrorAction Stop
Write-Ok "PnP.PowerShell module loaded."

# ----------------------------------------------------------------------------
# 3. Prompt for connection details
# ----------------------------------------------------------------------------

Write-Step "Tenant / site connection details"

Write-Host "Enter the details for the SharePoint site you want to connect to."
Write-Host "(This is just to verify connectivity - source/destination/threshold for"
Write-Host " the archive job itself are configured separately if you save to Clients.json.)"
Write-Host ""

$clientName    = Read-Host "Friendly client name (e.g. Contoso)"
$siteUrl       = Read-Host "Site URL to test (e.g. https://contoso.sharepoint.com/sites/Finance)"
$tenantId      = Read-Host "Tenant ID (e.g. contoso.onmicrosoft.com)"
$appClientId   = Read-Host "App registration Client ID (Application ID GUID)"
$certPath      = Read-Host "Path to .pfx certificate (e.g. C:\certs\SPArchiver-Contoso.pfx)"

if (-not (Test-Path $certPath)) {
    Write-Warn2 "Certificate file not found at that path: $certPath"
    $proceedAnyway = Read-Host "Continue anyway? (y/N)"
    if ($proceedAnyway -notmatch '^[Yy]') {
        throw "Aborted - certificate path not found."
    }
}

$certHasPassword = Read-Host "Does the .pfx have a password? (Y/n)"
$certPassword = $null
$certPasswordPlain = $null
if ($certHasPassword -notmatch '^[Nn]') {
    $certPassword = Read-Host "Enter certificate password" -AsSecureString
    # Keep a plain copy only in memory, only if user later chooses to save it to Clients.json.
    # NOTE: storing cert passwords in plaintext JSON is not great practice - see warning below.
    $certPasswordPlain = [System.Net.NetworkCredential]::new("", $certPassword).Password
}

# ----------------------------------------------------------------------------
# 4. Connect and verify
# ----------------------------------------------------------------------------

Write-Step "Connecting to $siteUrl"

try {
    $connectParams = @{
        Url             = $siteUrl
        ClientId        = $appClientId
        Tenant          = $tenantId
        CertificatePath = $certPath
    }
    if ($certPassword) { $connectParams["CertificatePassword"] = $certPassword }

    Connect-PnPOnline @connectParams
    $site = Get-PnPSite
    $web  = Get-PnPWeb

    Write-Ok "Connected successfully."
    Write-Host "      Site title: $($web.Title)"
    Write-Host "      Site URL:   $($site.Url)"

    Disconnect-PnPOnline
}
catch {
    Write-Err2 "Connection failed: $($_.Exception.Message)"
    Write-Warn2 "Common causes: cert not uploaded to the app registration, admin consent not"
    Write-Warn2 "granted, wrong Tenant ID, or Sites.Selected permission not granted on this site."
    Write-Warn2 "See Setup-AppRegistration.md for the one-time setup steps."
    throw
}

# ----------------------------------------------------------------------------
# 5. Offer to save into Clients.json
# ----------------------------------------------------------------------------

Write-Step "Save these details for future runs?"

$save = Read-Host "Save '$clientName' into $ConfigPath so you don't have to re-enter this? (Y/n)"

if ($save -match '^[Nn]') {
    Write-Host "Skipped saving. You can add this client manually later using Clients.example.json as a template."
    return
}

# Load existing config or start fresh
$clients = @()
if (Test-Path $ConfigPath) {
    try {
        $existing = Get-Content $ConfigPath -Raw | ConvertFrom-Json
        $clients = @($existing)
    }
    catch {
        Write-Warn2 "Existing $ConfigPath could not be parsed as JSON. A backup will be made and a new file started."
        Copy-Item $ConfigPath "$ConfigPath.bak-$(Get-Date -Format 'yyyyMMddHHmmss')"
    }
}

# Check for a name collision
$existingEntry = $clients | Where-Object { $_.Name -eq $clientName }
if ($existingEntry) {
    Write-Warn2 "A client named '$clientName' already exists in $ConfigPath."
    $overwrite = Read-Host "Overwrite it? (y/N)"
    if ($overwrite -notmatch '^[Yy]') {
        Write-Host "Skipped saving - left existing entry untouched."
        return
    }
    $clients = $clients | Where-Object { $_.Name -ne $clientName }
}

Write-Host ""
Write-Host "This connection test only confirmed site access. The archive job also needs:"
Write-Host "  - a SOURCE library, a DESTINATION site/library, and an inactivity threshold."
Write-Host "You can fill these in now, or accept the defaults and edit $ConfigPath later."
Write-Host ""

$sourceLibrary     = Read-Host "Source library name [default: Documents]"
if (-not $sourceLibrary) { $sourceLibrary = "Documents" }

$destSiteUrl       = Read-Host "Destination (archive) site URL [default: same as source site]"
if (-not $destSiteUrl) { $destSiteUrl = $siteUrl }

$destLibrary       = Read-Host "Destination library name [default: same as source library]"
if (-not $destLibrary) { $destLibrary = $sourceLibrary }

$threshold         = Read-Host "Months inactive threshold [default: 24]"
if (-not $threshold) { $threshold = 24 } else { $threshold = [int]$threshold }

$newEntry = [PSCustomObject]@{
    Name                    = $clientName
    Enabled                 = $true
    SourceSiteUrl           = $siteUrl
    SourceLibrary           = $sourceLibrary
    DestinationSiteUrl      = $destSiteUrl
    DestinationLibrary      = $destLibrary
    MonthsInactiveThreshold = $threshold
    AppClientId             = $appClientId
    TenantId                = $tenantId
    CertificatePath         = $certPath
    CertificatePassword     = $certPasswordPlain
    ExcludeFolders          = @("_PendingDelete", "DoNotArchive")
}

$clients += $newEntry

$clients | ConvertTo-Json -Depth 5 | Set-Content -Path $ConfigPath -Encoding UTF8

Write-Ok "Saved '$clientName' to $ConfigPath"

if ($certPasswordPlain) {
    Write-Host ""
    Write-Warn2 "Certificate password was saved in plaintext inside $ConfigPath."
    Write-Warn2 "For production use, consider removing 'CertificatePassword' from the file and"
    Write-Warn2 "instead retrieving it at runtime from a secrets store (Azure Key Vault, etc),"
    Write-Warn2 "or protect the file itself with restrictive NTFS permissions / encryption."
}

Write-Host ""
Write-Host "Setup complete. You can now run:" -ForegroundColor Cyan
Write-Host "  .\Run-QuarterlyArchive.ps1 -ConfigPath '$ConfigPath' -ClientName '$clientName'"
Write-Host "(dry-run by default - add -LiveRun once you've reviewed the candidate CSV)"
