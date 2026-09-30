# Disable Browser Notifications & Scareware Defenses
# Run as Administrator

#Requires -RunAsAdministrator

Write-Host "=== Browser Security Hardening ===" -ForegroundColor Green

# 1. MICROSOFT EDGE - Disable notifications via Group Policy
Write-Host "[+] Configuring Microsoft Edge policies..."
$EdgePoliciesPath = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
if (-not (Test-Path $EdgePoliciesPath)) {
    New-Item -Path $EdgePoliciesPath -Force | Out-Null
}

# Disable push notifications
Set-ItemProperty -Path $EdgePoliciesPath -Name "NotificationAllowed" -Value 0 -Force
Write-Host "  - Notifications disabled"

# Disable JavaScript (aggressive - breaks many sites)
# Set-ItemProperty -Path $EdgePoliciesPath -Name "JavaScriptAllowed" -Value 0 -Force

# Disable popup windows
Set-ItemProperty -Path $EdgePoliciesPath -Name "PopupsAllowed" -Value 0 -Force
Write-Host "  - Popups disabled"

# Block insecure content
Set-ItemProperty -Path $EdgePoliciesPath -Name "InsecureContentAllowed" -Value 0 -Force
Write-Host "  - Insecure content blocked"

# 2. GOOGLE CHROME - Disable notifications
Write-Host "[+] Configuring Google Chrome policies..."
$ChromePoliciesPath = "HKLM:\SOFTWARE\Policies\Google\Chrome"
if (-not (Test-Path $ChromePoliciesPath)) {
    New-Item -Path $ChromePoliciesPath -Force | Out-Null
}

Set-ItemProperty -Path $ChromePoliciesPath -Name "NotificationAllowed" -Value 0 -Force
Write-Host "  - Notifications disabled"

Set-ItemProperty -Path $ChromePoliciesPath -Name "PopupsAllowed" -Value 0 -Force
Write-Host "  - Popups disabled"

# 3. USER-LEVEL Edge preferences (current user)
Write-Host "[+] Configuring user-level preferences..."
$UserEdgePrefs = "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Preferences"
if (Test-Path $UserEdgePrefs) {
    try {
        $prefs = Get-Content $UserEdgePrefs | ConvertFrom-Json
        
        # Disable notifications permission by default
        if (-not $prefs.profile.default_content_settings) {
            $prefs.profile.default_content_settings = @{}
        }
        $prefs.profile.default_content_settings.notifications = 2  # 2 = block
        
        $prefs | ConvertTo-Json -Depth 32 | Set-Content $UserEdgePrefs
        Write-Host "  - Edge user preferences updated"
    }
    catch {
        Write-Host "  - Could not modify Edge preferences (may need Edge closed)" -ForegroundColor Yellow
    }
}

# 4. HOSTS FILE - Block known scareware domains
Write-Host "[+] Adding scareware domains to hosts file..."
$hostsPath = "C:\Windows\System32\drivers\etc\hosts"
$scarewareDomains = @(
    "cikadron.co.in",
    "fakealert.com",
    "systemalert.net",
    "alertsystem.net",
    "antivirusalert.com"
)

$hostsContent = Get-Content $hostsPath
$added = 0
foreach ($domain in $scarewareDomains) {
    if ($hostsContent -notcontains "127.0.0.1 $domain") {
        Add-Content -Path $hostsPath -Value "127.0.0.1 $domain" -Force
        $added++
    }
}
Write-Host "  - Added $added domains to hosts file"

# 5. WINDOWS DEFENDER SmartScreen
Write-Host "[+] Enabling Windows Defender SmartScreen..."
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" `
    -Name "EnableSmartScreen" -Value 1 -Force
Write-Host "  - SmartScreen enabled"

Write-Host "`n=== Hardening Complete ===" -ForegroundColor Green
Write-Host "NOTE: Close all browsers and restart for policies to apply" -ForegroundColor Yellow
Write-Host "`nBest practices:" -ForegroundColor Cyan
Write-Host "  1. Educate users: Real OS alerts don't come from web browsers"
Write-Host "  2. Install uBlock Origin for ad/popup blocking"
Write-Host "  3. Keep Windows Defender/AV definitions updated"
Write-Host "  4. Enable Windows Defender SmartScreen (now enabled)"
Write-Host "  5. Use DNS filtering (e.g., Cloudflare 1.1.1.1 or Quad9)"
