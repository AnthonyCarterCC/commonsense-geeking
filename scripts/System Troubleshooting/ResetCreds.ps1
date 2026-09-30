<#
.SYNOPSIS
    Finds and removes stored Adobe and Microsoft credentials from Windows
    Credential Manager (Generic / Web credentials visible to cmdkey).

.DESCRIPTION
    Enumerates all credentials in Credential Manager via cmdkey /list,
    filters for entries whose Target or User references Adobe or Microsoft
    (Office, Outlook, OneDrive, Azure AD, live.com, MSA, Teams, etc.), shows
    you the list, and deletes them after confirmation.

    Run this in an elevated ("Run as Administrator") PowerShell or terminal
    window. It only touches the credentials stored for the CURRENT Windows
    user profile you run it as.

.PARAMETER WhatIf
    Preview only — lists matching credentials but deletes nothing.

.PARAMETER Force
    Skip the interactive Y/N prompt and delete all matches immediately.

.EXAMPLE
    .\Reset-AdobeMicrosoftCredentials.ps1 -WhatIf
    .\Reset-AdobeMicrosoftCredentials.ps1
    .\Reset-AdobeMicrosoftCredentials.ps1 -Force

.NOTES
    - Covers "Generic" and "Windows" credentials as shown by `cmdkey /list`
      (this includes most saved app/web logins, e.g. Adobe Creative Cloud,
      Office/Outlook saved passwords).
    - Does NOT sign you out of accounts added under Windows Settings ->
      Accounts -> "Access work or school" / "Email & accounts" (these are
      managed differently, e.g. via WAM/Azure AD join). If you also need
      those removed, do it manually from Settings, or ask and a follow-up
      snippet can be added for that.
    - After running, you will need to re-enter credentials next time each
      app/site asks.
#>

[CmdletBinding()]
param(
    [switch]$WhatIf,
    [switch]$Force
)

# --- Require elevation ---
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warning "This script should be run from an elevated (Administrator) PowerShell/terminal window."
    Write-Warning "Right-click PowerShell/Terminal -> 'Run as administrator', then re-run this script."
    exit 1
}

# --- Keywords to match (case-insensitive) ---
$keywords = @(
    'adobe',
    'creativecloud',
    'microsoft',
    'msa',
    'live.com',
    'outlook',
    'office365',
    'office16',
    'onedrive',
    'azuread',
    'login.microsoftonline',
    'msteams',
    'teams.microsoft'
)

# --- Get raw cmdkey output ---
$raw = cmdkey /list 2>$null
if (-not $raw) {
    Write-Host "No stored credentials found (or cmdkey returned nothing)." -ForegroundColor Yellow
    exit 0
}

# --- Parse into credential blocks ---
$blocks = @()
$current = $null

foreach ($line in $raw) {
    $line = $line.TrimEnd()

    if ($line -match '^\s*Target:\s*(.+)$') {
        if ($current) { $blocks += $current }
        $current = [PSCustomObject]@{
            Target = $Matches[1].Trim()
            Type   = $null
            User   = $null
        }
    }
    elseif ($line -match '^\s*Type:\s*(.+)$' -and $current) {
        $current.Type = $Matches[1].Trim()
    }
    elseif ($line -match '^\s*User:\s*(.+)$' -and $current) {
        $current.User = $Matches[1].Trim()
    }
}
if ($current) { $blocks += $current }

if ($blocks.Count -eq 0) {
    Write-Host "No stored credentials found." -ForegroundColor Yellow
    exit 0
}

# --- Filter for Adobe / Microsoft matches ---
$pattern = ($keywords | ForEach-Object { [regex]::Escape($_) }) -join '|'
$matches = $blocks | Where-Object {
    ($_.Target -match $pattern) -or ($_.User -match $pattern)
}

if ($matches.Count -eq 0) {
    Write-Host "No Adobe or Microsoft credentials found in Credential Manager." -ForegroundColor Green
    exit 0
}

Write-Host ""
Write-Host "Found $($matches.Count) matching credential(s):" -ForegroundColor Cyan
Write-Host ""
$matches | ForEach-Object {
    Write-Host ("  Target: {0}" -f $_.Target)
    Write-Host ("  Type:   {0}" -f $_.Type)
    Write-Host ("  User:   {0}" -f $_.User)
    Write-Host ""
}

if ($WhatIf) {
    Write-Host "Dry run (-WhatIf) — nothing was deleted." -ForegroundColor Yellow
    exit 0
}

if (-not $Force) {
    $confirmation = Read-Host "Delete ALL $($matches.Count) credential(s) listed above? (Y/N)"
    if ($confirmation -notmatch '^[Yy]') {
        Write-Host "Aborted. No credentials were deleted." -ForegroundColor Yellow
        exit 0
    }
}

# --- Delete ---
$deleted = 0
$failed  = 0

foreach ($cred in $matches) {
    Write-Host "Deleting: $($cred.Target) ..." -NoNewline
    $result = cmdkey /delete:"$($cred.Target)" 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host " OK" -ForegroundColor Green
        $deleted++
    } else {
        Write-Host " FAILED" -ForegroundColor Red
        Write-Host "    $result" -ForegroundColor DarkRed
        $failed++
    }
}

Write-Host ""
Write-Host "Done. Deleted: $deleted, Failed: $failed" -ForegroundColor Cyan

if ($failed -gt 0) {
    Write-Host "Some credentials could not be removed via cmdkey. These may need to be removed manually from:" -ForegroundColor Yellow
    Write-Host "  Control Panel -> Credential Manager -> Windows Credentials / Web Credentials" -ForegroundColor Yellow
}