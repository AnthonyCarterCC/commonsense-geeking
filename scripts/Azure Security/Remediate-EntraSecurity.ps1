<#
.SYNOPSIS
    Closes the two remaining gaps found by Audit-EntraSecurity.ps1:
      1. MFA is only enforced for admins/risky sign-ins, not all users.
      2. Smart Lockout threshold/duration not confirmed.

    Your tenant already has: legacy auth blocked, country allow-list (Australia),
    admin MFA, risky sign-in MFA, device code blocked. This script does NOT
    duplicate those.

.NOTES
    - Requires Conditional Access Administrator (for CA policy) and
      Global Administrator / Authentication Policy Administrator (for lockout settings).
    - The new MFA policy is created in "enabledForReportingButNotEnforced" mode.
      Review impact in Conditional Access > Insights before flipping to "enabled".
    - IMPORTANT: Before enabling, make sure you have a break-glass/emergency access
      account excluded from the policy, or you can lock yourself out.
#>

$ErrorActionPreference = "Stop"

Connect-MgGraph -Scopes @(
    "Policy.ReadWrite.ConditionalAccess",
    "Policy.Read.All",
    "Directory.Read.All",
    "Policy.ReadWrite.AuthenticationMethod"
) -NoWelcome

# ---------------------------------------------------------------------------
# STEP 1: Require MFA for ALL users (currently admin-only + risk-based)
# ---------------------------------------------------------------------------

# >>> EDIT THIS: put your break-glass account's Object ID here before enabling <<<
$BreakGlassUserId = ""   # e.g. "11111111-2222-3333-4444-555555555555"

$PolicyState = "enabledForReportingButNotEnforced"

$excludeUsers = @()
if ($BreakGlassUserId) { $excludeUsers += $BreakGlassUserId }

$mfaAllUsersPolicy = @{
    displayName = "CA005 - Require MFA for All Users"
    state       = $PolicyState
    conditions  = @{
        users = @{
            includeUsers = @("All")
            excludeUsers = $excludeUsers
        }
        applications = @{
            includeApplications = @("All")
        }
    }
    grantControls = @{
        operator        = "OR"
        builtInControls = @("mfa")
    }
}

Write-Host "Creating: Require MFA for All Users ($PolicyState)..." -ForegroundColor Cyan
if (-not $BreakGlassUserId) {
    Write-Host "WARNING: No break-glass account excluded. Fill in `$BreakGlassUserId` before setting this policy to 'enabled'." -ForegroundColor Red
}
New-MgIdentityConditionalAccessPolicy -BodyParameter $mfaAllUsersPolicy | Out-Null

# ---------------------------------------------------------------------------
# STEP 2: Check and (optionally) tighten Smart Lockout
# ---------------------------------------------------------------------------

Write-Host "`nChecking Smart Lockout (Password Rule Settings)..." -ForegroundColor Cyan

$templates = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/directorySettingTemplates"
$pwTemplate = $templates.value | Where-Object { $_.displayName -eq "Password Rule Settings" }

$existingSettings = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/settings"
$pwSetting = $existingSettings.value | Where-Object { $_.templateId -eq $pwTemplate.id }

if ($pwSetting) {
    Write-Host "Current tenant Smart Lockout settings:"
    $pwSetting.values | Where-Object { $_.name -match "Lockout" } | Format-Table -AutoSize
} else {
    Write-Host "No tenant-level override found — tenant is using Microsoft defaults:" -ForegroundColor Yellow
    Write-Host "  LockoutThreshold: 10 attempts"
    Write-Host "  LockoutDurationInSeconds: 60"
    Write-Host "Given the distributed low-and-slow pattern in your sign-in logs (2-3 attempts per IP across many IPs)," -ForegroundColor Yellow
    Write-Host "the default threshold of 10 won't trigger lockout at all. Recommend tightening to 5." -ForegroundColor Yellow
}

# Uncomment to actually tighten the threshold to 5 attempts / 300 second lockout:
<#
$body = @{
    templateId = $pwTemplate.id
    values = @(
        @{ name = "LockoutThreshold"; value = "5" }
        @{ name = "LockoutDurationInSeconds"; value = "300" }
        @{ name = "BannedPasswordCheckOnPremisesMode"; value = "Audit" }
    )
}
if ($pwSetting) {
    Invoke-MgGraphRequest -Method PATCH -Uri "https://graph.microsoft.com/beta/settings/$($pwSetting.id)" -Body $body
    Write-Host "Updated existing Smart Lockout settings." -ForegroundColor Green
} else {
    Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/beta/settings" -Body $body
    Write-Host "Created tenant-level Smart Lockout override." -ForegroundColor Green
}
#>

Write-Host "`nDone." -ForegroundColor Green
Write-Host "1. Set `$BreakGlassUserId at the top of this script, then flip CA005 to 'enabled' once report-only looks clean." -ForegroundColor Yellow
Write-Host "2. Uncomment the Smart Lockout block above to tighten threshold to 5 attempts / 5 min lockout." -ForegroundColor Yellow
