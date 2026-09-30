#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Promotes the currently signed-in Entra ID (Azure AD) user to the local Administrators
    group on this Entra-joined machine.

.DESCRIPTION
    Designed for the scenario where:
      - The device is Microsoft Entra ID (Azure AD) joined (not hybrid/on-prem AD joined).
      - The person sitting at the machine is signed in with a standard (non-admin) Entra
        ID account.
      - You are running THIS script from a separate elevated PowerShell/terminal window
        (e.g. launched with a break-glass local administrator account, or "Run as
        different user" using an existing admin account) - NOT from a UAC elevation of
        the standard user's own session, since a standard user cannot elevate themselves.

    The script does not rely on $env:USERNAME or the identity the script itself is running
    as (that will typically be the admin account you used to elevate). Instead it queries
    Win32_ComputerSystem to find the account that is actually logged on to the interactive
    (console) session, which is the AAD user you want to promote.

    On an Entra-joined device, that value is normally reported in the form:
        AzureAD\user@yourtenant.com

    The script then adds that account to the built-in local Administrators group
    (SID S-1-5-32-544, so it works regardless of OS language/locale).

.PARAMETER TargetUser
    Optional. Explicitly specify the account to promote (e.g. "AzureAD\jane@contoso.com").
    If omitted, the script auto-detects the interactively logged-on user.

.PARAMETER WhatIf
    Show what would happen without making any change.

.EXAMPLE
    .\Promote-CurrentUserToLocalAdmin.ps1

.EXAMPLE
    .\Promote-CurrentUserToLocalAdmin.ps1 -TargetUser "AzureAD\jane@contoso.com"

.NOTES
    - Must be run from an elevated ("Run as Administrator") PowerShell session.
    - The promoted user must sign out and back in (or the machine must be rebooted) before
      Windows issues them a token that reflects the new group membership.
    - Adding someone to local Administrators is a meaningful privilege escalation. Prefer a
      time-limited / just-in-time elevation tool (e.g. Entra PIM for Groups, Windows LAPS +
      JIT, or Microsoft Endpoint Manager's Azure AD "local admin" workflows) for production
      environments where possible. This script is provided for ad-hoc / helpdesk scenarios.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $false)]
    [string]$TargetUser
)

$ErrorActionPreference = 'Stop'

function Assert-Elevated {
    $identity  = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "This script must be run from an elevated PowerShell session (Run as Administrator)."
    }
}

function Test-EntraJoined {
    try {
        $status = dsregcmd /status 2>$null
        $line   = $status | Select-String -Pattern '^\s*AzureAdJoined\s*:\s*(YES|NO)' -CaseSensitive:$false
        if ($line -and $line.Matches[0].Groups[1].Value -ieq 'YES') {
            return $true
        }
        return $false
    }
    catch {
        Write-Warning "Could not run dsregcmd /status to confirm Entra join state: $_"
        return $null
    }
}

function Get-InteractiveLogonUser {
    # Win32_ComputerSystem.UserName reflects the account signed in to the interactive
    # (console) session - independent of whatever account this elevated script is running as.
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($cs.UserName)) {
        return $null
    }
    return $cs.UserName
}

# --- 1. Preconditions -------------------------------------------------------

Assert-Elevated

$joinState = Test-EntraJoined
switch ($joinState) {
    $true   { Write-Host "Device is Entra ID (Azure AD) joined." -ForegroundColor Green }
    $false  { Write-Warning "dsregcmd reports this device is NOT Azure AD joined. Double-check you're on the right machine before continuing." }
    default { Write-Warning "Entra join state could not be verified; continuing anyway." }
}

# --- 2. Resolve which account to promote ------------------------------------

if ($TargetUser) {
    $account = $TargetUser
    Write-Host "Using explicitly specified account: $account"
}
else {
    $account = Get-InteractiveLogonUser
    if (-not $account) {
        throw "Could not determine the interactively logged-on user. Re-run with -TargetUser 'AzureAD\user@domain.com'."
    }
    Write-Host "Detected interactively logged-on account: $account"
    if ($account -notmatch '^AzureAD\\') {
        Write-Warning "Expected an account in the form 'AzureAD\<UPN>' for an Entra-joined device, but got '$account'. Proceeding, but confirm this is the correct account."
    }
}

# --- 3. Check current membership --------------------------------------------

$adminGroup = Get-LocalGroup -SID 'S-1-5-32-544'  # Built-in "Administrators" group, locale-independent

$isMember = $false
try {
    $members = Get-LocalGroupMember -Group $adminGroup.Name -ErrorAction Stop
    $isMember = [bool]($members | Where-Object { $_.Name -ieq $account })
}
catch {
    Write-Warning "Could not enumerate existing members of '$($adminGroup.Name)': $_"
}

if ($isMember) {
    Write-Host "$account is already a member of the local '$($adminGroup.Name)' group. Nothing to do." -ForegroundColor Yellow
    return
}

# --- 4. Add the account -------------------------------------------------------

if ($PSCmdlet.ShouldProcess($account, "Add to local '$($adminGroup.Name)' group")) {
    try {
        Add-LocalGroupMember -Group $adminGroup.Name -Member $account -ErrorAction Stop
        Write-Host "Success: added '$account' to the local '$($adminGroup.Name)' group." -ForegroundColor Green
    }
    catch {
        Write-Warning "Add-LocalGroupMember failed: $_"
        Write-Host "Retrying with 'net localgroup' as a fallback..."
        $result = & net localgroup Administrators "$account" /add 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to add '$account' to Administrators via both Add-LocalGroupMember and net.exe. Last output: $result"
        }
        Write-Host "Success (via net.exe): added '$account' to the local Administrators group." -ForegroundColor Green
    }

    Write-Host ""
    Write-Host "NOTE: '$account' must sign out and back in (or the machine must be rebooted) before Windows issues a token reflecting local admin rights." -ForegroundColor Cyan
}
