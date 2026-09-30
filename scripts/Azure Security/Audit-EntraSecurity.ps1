<#
.SYNOPSIS
    Read-only audit of Entra ID (Azure AD) security posture relevant to brute-force / legacy-auth attacks.
    Makes NO changes. Run this first.

.REQUIREMENTS
    - PowerShell 5.1+ or PowerShell 7+
    - Internet access to PSGallery and login.microsoftonline.com / graph.microsoft.com
    - An account with at least Security Reader / Global Reader / Reports Reader role in Entra ID
    - Modules (auto-installed/imported below if missing):
        Microsoft.Graph.Authentication
        Microsoft.Graph.Identity.SignIns
        Microsoft.Graph.Identity.DirectoryManagement
        Microsoft.Graph.Reports
#>

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# STEP 0: Prerequisites — ensure required modules are installed and loaded
# ---------------------------------------------------------------------------

Write-Host "Checking prerequisites..." -ForegroundColor Cyan

$requiredModules = @(
    "Microsoft.Graph.Authentication",
    "Microsoft.Graph.Identity.SignIns",
    "Microsoft.Graph.Identity.DirectoryManagement",
    "Microsoft.Graph.Reports"
)

# NuGet provider is needed by Install-Module the first time it's ever run on a machine.
if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)) {
    Write-Host "Installing NuGet provider..." -ForegroundColor Yellow
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
}

# Trust PSGallery so Install-Module doesn't prompt interactively.
$psGallery = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue
if ($psGallery -and $psGallery.InstallationPolicy -ne "Trusted") {
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
}

foreach ($module in $requiredModules) {
    $installed = Get-Module -ListAvailable -Name $module
    if (-not $installed) {
        Write-Host "  Installing $module ..." -ForegroundColor Yellow
        Install-Module -Name $module -Scope CurrentUser -Force -AllowClobber
    }
    Write-Host "  Importing $module ..." -ForegroundColor DarkGray
    Import-Module -Name $module -ErrorAction Stop
}

Write-Host "Prerequisites OK." -ForegroundColor Green

# ---------------------------------------------------------------------------
# STEP 0b: Connect to Microsoft Graph
# ---------------------------------------------------------------------------

Write-Host "`nConnecting to Microsoft Graph (a browser sign-in window may open)..." -ForegroundColor Cyan
Connect-MgGraph -Scopes @(
    "Policy.Read.All",
    "Directory.Read.All",
    "IdentityRiskyUser.Read.All",
    "AuditLog.Read.All"
) -NoWelcome

$context = Get-MgContext
if (-not $context) {
    throw "Not connected to Microsoft Graph. Aborting."
}
Write-Host "Connected as $($context.Account) to tenant $($context.TenantId)." -ForegroundColor Green

Write-Host "`n===== 1. Security Defaults =====" -ForegroundColor Yellow
try {
    $secDefaults = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/policies/identitySecurityDefaultsEnforcementPolicy"
    Write-Host "Security Defaults enabled: $($secDefaults.isEnabled)"
} catch {
    Write-Host "Could not read security defaults: $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host "`n===== 2. Conditional Access Policies =====" -ForegroundColor Yellow
$caPolicies = Get-MgIdentityConditionalAccessPolicy -All
if (-not $caPolicies) {
    Write-Host "No Conditional Access policies found. (This explains 'Not applied' on every sign-in.)" -ForegroundColor Red
} else {
    $caPolicies | Select-Object DisplayName, State, Id |
        Format-Table -AutoSize
}

Write-Host "`n===== 3. Legacy Authentication Block Check =====" -ForegroundColor Yellow
$legacyBlocked = $caPolicies | Where-Object {
    $_.Conditions.ClientAppTypes -contains "exchangeActiveSync" -or
    $_.Conditions.ClientAppTypes -contains "other"
} | Where-Object { $_.GrantControls.BuiltInControls -contains "block" -and $_.State -eq "enabled" }

if ($legacyBlocked) {
    Write-Host "Legacy auth appears to be blocked by policy: $($legacyBlocked.DisplayName)" -ForegroundColor Green
} else {
    Write-Host "No enabled policy found that blocks legacy authentication." -ForegroundColor Red
}

Write-Host "`n===== 4. Named Locations =====" -ForegroundColor Yellow
$namedLocations = Get-MgIdentityConditionalAccessNamedLocation -All
if ($namedLocations) {
    $namedLocations | Select-Object DisplayName, Id | Format-Table -AutoSize
} else {
    Write-Host "No named locations configured." -ForegroundColor Red
}

Write-Host "`n===== 5. Identity Protection Risk Policies (requires Entra P2) =====" -ForegroundColor Yellow
try {
    $riskPolicy = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/identityProtection/riskyUsers?`$top=5"
    Write-Host "Identity Protection API reachable — P2 features likely licensed."
} catch {
    Write-Host "Identity Protection risk data not available (likely no P2 license, or insufficient permissions)." -ForegroundColor Red
}

Write-Host "`n===== 6. Recent Failed Sign-ins (last 24h, top offending IPs) =====" -ForegroundColor Yellow
$signIns = Get-MgAuditLogSignIn -Filter "status/errorCode ne 0" -Top 200
$signIns | Group-Object { $_.IpAddress } | Sort-Object Count -Descending | Select-Object -First 15 |
    Select-Object Count, Name | Format-Table -AutoSize

Write-Host "`n===== 7. Smart Lockout (tenant default — no direct Graph read; confirm in portal) =====" -ForegroundColor Yellow
Write-Host "Entra ID > Security > Authentication methods > Password protection blade to confirm lockout threshold/duration."

Write-Host "`nAudit complete. Review the red items above — those are the gaps to close." -ForegroundColor Cyan
