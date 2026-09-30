<#
.SYNOPSIS
    Updates the ExchangeOnlineManagement module and enables DKIM signing
    for one or more accepted domains in Microsoft 365 / Exchange Online.

.DESCRIPTION
    - Ensures the ExchangeOnlineManagement PowerShell module is installed and up to date
    - Connects to Exchange Online
    - Checks whether DKIM CNAME records exist in DNS for the target domain
    - Creates the DKIM signing config if it doesn't exist
    - Enables DKIM signing on the domain
    - Reports the CNAME records you need to publish if they're missing

.NOTES
    Run this in an elevated PowerShell window (Run as Administrator).
    You must be a Global Admin or Exchange Admin in the Microsoft 365 tenant.

.EXAMPLE
    .\Enable-DKIM-O365.ps1 -Domain "contoso.com"
#>

param(
    [Parameter(Mandatory = $true, HelpMessage = "The domain to enable DKIM for, e.g. contoso.com")]
    [string]$Domain,

    [Parameter(Mandatory = $false, HelpMessage = "The admin UPN to sign in with, e.g. admin@customediaoz.onmicrosoft.com")]
    [string]$UserPrincipalName
)

$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    Write-Host "`n=== $Message ===" -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
# 1. Ensure the ExchangeOnlineManagement module is installed and up to date
# ---------------------------------------------------------------------------
Write-Step "Checking ExchangeOnlineManagement module"

$moduleName = "ExchangeOnlineManagement"
$installedModule = Get-Module -ListAvailable -Name $moduleName | Sort-Object Version -Descending | Select-Object -First 1

if (-not $installedModule) {
    Write-Host "Module not found. Installing $moduleName from PSGallery..."
    Install-Module -Name $moduleName -Scope CurrentUser -Force -AllowClobber
}
else {
    Write-Host "Found version $($installedModule.Version). Checking for updates..."
    try {
        Update-Module -Name $moduleName -Force
        Write-Host "Module updated (or already at latest version)."
    }
    catch {
        Write-Warning "Update-Module failed, attempting a clean reinstall: $($_.Exception.Message)"
        Install-Module -Name $moduleName -Scope CurrentUser -Force -AllowClobber
    }
}

Import-Module $moduleName -Force

# ---------------------------------------------------------------------------
# 2. Connect to Exchange Online
# ---------------------------------------------------------------------------
Write-Step "Connecting to Exchange Online"
Write-Host "A sign-in window will open — authenticate with an account that has Global Admin or Exchange Admin rights."

if ($UserPrincipalName) {
    Connect-ExchangeOnline -UserPrincipalName $UserPrincipalName -ShowBanner:$false
}
else {
    Connect-ExchangeOnline -ShowBanner:$false
}

# ---------------------------------------------------------------------------
# 3. Check current DKIM config for the domain
# ---------------------------------------------------------------------------
Write-Step "Checking existing DKIM configuration for $Domain"

$dkimConfig = Get-DkimSigningConfig -Identity $Domain -ErrorAction SilentlyContinue

if (-not $dkimConfig) {
    Write-Host "No DKIM config found for $Domain. Creating one now..."
    New-DkimSigningConfig -DomainName $Domain -Enabled $false | Out-Null
    $dkimConfig = Get-DkimSigningConfig -Identity $Domain
}
else {
    Write-Host "Existing DKIM config found. Current status: Enabled = $($dkimConfig.Enabled)"
}

# ---------------------------------------------------------------------------
# 4. Show the required CNAME records
# ---------------------------------------------------------------------------
Write-Step "Required DNS CNAME records"

$selector1Host = "selector1._domainkey.$Domain"
$selector2Host = "selector2._domainkey.$Domain"

Write-Host "Publish these two CNAME records at your DNS provider if you haven't already:`n"
Write-Host "  Host: selector1._domainkey  ->  Points to: $($dkimConfig.Selector1CNAME)"
Write-Host "  Host: selector2._domainkey  ->  Points to: $($dkimConfig.Selector2CNAME)`n"

# ---------------------------------------------------------------------------
# 5. Verify DNS resolution before enabling (best-effort check)
# ---------------------------------------------------------------------------
Write-Step "Verifying DNS records resolve correctly"

function Test-CnameRecord {
    param([string]$RecordName, [string]$ExpectedTarget)

    try {
        $result = Resolve-DnsName -Name $RecordName -Type CNAME -ErrorAction Stop
        $actual = ($result | Where-Object { $_.Type -eq "CNAME" } | Select-Object -First 1).NameHost
        if ($actual -and $actual.TrimEnd('.') -eq $ExpectedTarget.TrimEnd('.')) {
            Write-Host "  OK: $RecordName -> $actual" -ForegroundColor Green
            return $true
        }
        else {
            Write-Warning "  Mismatch or not found: $RecordName resolved to '$actual', expected '$ExpectedTarget'"
            return $false
        }
    }
    catch {
        Write-Warning "  Could not resolve $RecordName : $($_.Exception.Message)"
        return $false
    }
}

$sel1Ok = Test-CnameRecord -RecordName $selector1Host -ExpectedTarget $dkimConfig.Selector1CNAME
$sel2Ok = Test-CnameRecord -RecordName $selector2Host -ExpectedTarget $dkimConfig.Selector2CNAME

# ---------------------------------------------------------------------------
# 6. Enable DKIM signing
# ---------------------------------------------------------------------------
Write-Step "Enabling DKIM signing for $Domain"

if ($sel1Ok -and $sel2Ok) {
    Set-DkimSigningConfig -Identity $Domain -Enabled $true
    Write-Host "DKIM signing enabled successfully for $Domain." -ForegroundColor Green
}
else {
    Write-Warning "DNS CNAME records are not confirmed yet. Enabling anyway is possible, but mail may not validate until DNS propagates."
    $confirmation = Read-Host "Do you want to enable DKIM anyway? (Y/N)"
    if ($confirmation -match '^[Yy]') {
        Set-DkimSigningConfig -Identity $Domain -Enabled $true
        Write-Host "DKIM signing enabled for $Domain. Confirm DNS propagation separately." -ForegroundColor Yellow
    }
    else {
        Write-Host "Skipped enabling DKIM. Publish the CNAME records above, wait for DNS propagation, then re-run this script." -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------------------
# 7. Final status check
# ---------------------------------------------------------------------------
Write-Step "Final DKIM status"
Get-DkimSigningConfig -Identity $Domain | Format-List Domain, Enabled, Selector1CNAME, Selector2CNAME, Status

Write-Step "Done"
Write-Host "Disconnecting from Exchange Online..."
Disconnect-ExchangeOnline -Confirm:$false
