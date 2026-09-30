#Requires -Modules PartnerCenter, PnP.PowerShell
<#
.SYNOPSIS
    Enumerates all SharePoint site URLs across all delegated client tenants
    and exports them to a CSV grouped by client.

.DESCRIPTION
    Connects once to Partner Center to retrieve all customer tenants,
    then uses PnP.PowerShell with GDAP delegated access to query each
    tenant's SharePoint sites via the SharePoint Admin REST API.

.NOTES
    Prerequisites:
        Install-Module PartnerCenter -Scope CurrentUser
        Install-Module PnP.PowerShell -Scope CurrentUser

    GDAP Requirements:
        Your GDAP role assignment must include one of:
          - SharePoint Administrator
          - Global Reader (can read site collections)

    The script authenticates once interactively and reuses the token
    for all subsequent tenant connections.

.OUTPUTS
    SharePoint_Sites_<timestamp>.csv with columns:
        ClientName, TenantDomain, SiteUrl, Title, Template, Status
#>

[CmdletBinding()]
param(
    # Optional: restrict to a specific client name (partial match, case-insensitive)
    [string]$FilterClient = "",

    # Output folder (defaults to script directory)
    [string]$OutputFolder = $PSScriptRoot,

    # Include OneDrive personal sites (MySites) — excluded by default
    [switch]$IncludeOneDrive,

    # Skip tenants that error rather than stopping the whole run
    [switch]$ContinueOnError
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ─── Output file ──────────────────────────────────────────────────────────────
$timestamp  = Get-Date -Format "yyyyMMdd_HHmmss"
$outputFile = Join-Path $OutputFolder "SharePoint_Sites_$timestamp.csv"

# ─── Results accumulator ──────────────────────────────────────────────────────
$allSites = [System.Collections.Generic.List[PSCustomObject]]::new()

# ══════════════════════════════════════════════════════════════════════════════
# STEP 1 — Authenticate to Partner Center (single interactive login)
# ══════════════════════════════════════════════════════════════════════════════
Write-Host "`n[1/3] Connecting to Partner Center..." -ForegroundColor Cyan

try {
    # Connect-PartnerCenter triggers a single device-code / browser login.
    # The resulting token is cached in the session for all subsequent calls.
    Connect-PartnerCenter -UseDeviceAuthentication
    Write-Host "      Partner Center connected." -ForegroundColor Green
}
catch {
    Write-Error "Failed to connect to Partner Center: $_"
    exit 1
}

# ══════════════════════════════════════════════════════════════════════════════
# STEP 2 — Retrieve customer list
# ══════════════════════════════════════════════════════════════════════════════
Write-Host "`n[2/3] Retrieving customer tenants..." -ForegroundColor Cyan

$customers = Get-PartnerCustomer

if ($FilterClient) {
    $customers = $customers | Where-Object { $_.Name -ilike "*$FilterClient*" }
    Write-Host "      Filter applied — $($customers.Count) tenant(s) matched '$FilterClient'."
}
else {
    Write-Host "      Found $($customers.Count) tenant(s)."
}

if (-not $customers) {
    Write-Warning "No customers found. Exiting."
    exit 0
}

# ══════════════════════════════════════════════════════════════════════════════
# STEP 3 — Enumerate SharePoint sites per tenant
# ══════════════════════════════════════════════════════════════════════════════
Write-Host "`n[3/3] Enumerating SharePoint sites...`n" -ForegroundColor Cyan

$i = 0
foreach ($customer in $customers) {

    $i++
    $clientName   = $customer.Name
    $tenantId     = $customer.CustomerId          # GUID
    $tenantDomain = $customer.Domain              # e.g. contoso.onmicrosoft.com

    Write-Host "  [$i/$($customers.Count)] $clientName ($tenantDomain)" -ForegroundColor White

    # Derive the SharePoint Admin URL from the primary domain.
    # Most tenants follow the <prefix>.sharepoint.com pattern.
    $spPrefix   = ($tenantDomain -replace "\.onmicrosoft\.com$", "") 
    $adminUrl   = "https://$spPrefix-admin.sharepoint.com"

    try {
        # Connect to this tenant's SharePoint Admin using the cached partner credentials.
        # -Url        = SharePoint Admin Center for the tenant
        # -TenantId   = target customer tenant GUID (GDAP delegated context)
        # -Interactive / -DeviceLogin triggers the cached SSO token — no second login needed
        #   when PnP re-uses the existing AzureAD session.
        Connect-PnPOnline `
            -Url         $adminUrl `
            -Interactive

        # Pull all site collections via the SharePoint Tenant Admin API
        $sites = Get-PnPTenantSite -IncludeOneDriveSites:$IncludeOneDrive.IsPresent

        if (-not $sites) {
            Write-Host "         (no sites found)" -ForegroundColor DarkGray
            continue
        }

        foreach ($site in $sites) {
            $allSites.Add([PSCustomObject]@{
                ClientName   = $clientName
                TenantDomain = $tenantDomain
                SiteUrl      = $site.Url
                Title        = $site.Title
                Template     = $site.Template
                Status       = $site.Status
            })
        }

        Write-Host "         → $($sites.Count) site(s)" -ForegroundColor Green

        # Disconnect cleanly before moving to next tenant
        Disconnect-PnPOnline
    }
    catch {
        $errMsg = $_.Exception.Message
        Write-Warning "      SKIPPED — $clientName : $errMsg"

        $allSites.Add([PSCustomObject]@{
            ClientName   = $clientName
            TenantDomain = $tenantDomain
            SiteUrl      = "ERROR"
            Title        = $errMsg
            Template     = ""
            Status       = "Error"
        })

        if (-not $ContinueOnError) {
            Write-Host "`n  Use -ContinueOnError to skip failed tenants and keep going." -ForegroundColor Yellow
            break
        }
    }
}

# ══════════════════════════════════════════════════════════════════════════════
# Export
# ══════════════════════════════════════════════════════════════════════════════
if ($allSites.Count -gt 0) {
    $allSites `
        | Sort-Object ClientName, SiteUrl `
        | Export-Csv -Path $outputFile -NoTypeInformation -Encoding UTF8

    Write-Host "`n✔  Exported $($allSites.Count) row(s) to:" -ForegroundColor Green
    Write-Host "   $outputFile" -ForegroundColor Cyan
}
else {
    Write-Warning "No data collected — CSV not written."
}
