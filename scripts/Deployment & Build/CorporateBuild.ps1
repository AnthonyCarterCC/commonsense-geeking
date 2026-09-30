#Requires -RunAsAdministrator
<#
    CorporateBuild.ps1
    Corporate Windows 11 endpoint build/hardening script.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

$Script:LogPath    = 'C:\Temp\CorporateBuild.log'
$Script:ReportPath = 'C:\Temp\BuildReport.txt'
$Script:Failures   = New-Object System.Collections.Generic.List[string]
$Script:BuildStart = Get-Date

# ============================================================
# CORE HELPERS
# ============================================================

function Initialize-Environment {
    if (-not (Test-Path -Path 'C:\Temp')) {
        New-Item -Path 'C:\Temp' -ItemType Directory -Force | Out-Null
    }
    if (-not (Test-Path -Path $Script:LogPath)) {
        New-Item -Path $Script:LogPath -ItemType File -Force | Out-Null
    }
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS')][string]$Level = 'INFO'
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$timestamp] [$Level] $Message"
    try {
        Add-Content -Path $Script:LogPath -Value $line -ErrorAction Stop
    } catch {
        Write-Host "LOGGING FAILURE: $($_.Exception.Message)"
    }
    switch ($Level) {
        'ERROR'   { Write-Host $line -ForegroundColor Red }
        'WARN'    { Write-Host $line -ForegroundColor Yellow }
        'SUCCESS' { Write-Host $line -ForegroundColor Green }
        default   { Write-Host $line }
    }
}

function Add-Failure {
    param([Parameter(Mandatory = $true)][string]$Message)
    $Script:Failures.Add($Message)
    Write-Log -Message $Message -Level 'ERROR'
}

function Invoke-SafeAction {
    param(
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)][scriptblock]$Action
    )
    try {
        Write-Log -Message "START: $Description"
        & $Action
        Write-Log -Message "OK: $Description" -Level 'SUCCESS'
        return $true
    } catch {
        Add-Failure -Message "FAILED: $Description :: $($_.Exception.Message)"
        return $false
    }
}

# ============================================================
# VALIDATION
# ============================================================

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-IsWindows11 {
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $build = [int]$os.BuildNumber
        return ($build -ge 22000)
    } catch {
        return $false
    }
}

function Confirm-Environment {
    if (-not (Test-IsAdministrator)) {
        Write-Log -Message 'Script must be run as Administrator. Exiting.' -Level 'ERROR'
        exit 1
    }
    if (-not (Test-IsWindows11)) {
        Write-Log -Message 'This script is only supported on Windows 11. Exiting.' -Level 'ERROR'
        exit 1
    }
    Write-Log -Message 'Environment validation passed: Administrator + Windows 11 confirmed.' -Level 'SUCCESS'
}

# ============================================================
# WINGET
# ============================================================

function Get-WingetPath {
    $cmd = Get-Command -Name 'winget.exe' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Test-WingetWorks {
    try {
        $wingetPath = Get-WingetPath
        if (-not $wingetPath) { return $false }
        $output = & $wingetPath --version 2>$null
        if ($LASTEXITCODE -eq 0 -and $output) { return $true }
        return $false
    } catch {
        return $false
    }
}

function Install-Winget {
    Invoke-SafeAction -Description 'Install/Repair Winget (App Installer)' -Action {
        $progressPref = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'

        try {
            Import-Module -Name Appx -UseWindowsPowerShell -ErrorAction SilentlyContinue
        } catch { }

        try {
            $vcLibs = Get-AppxPackage -Name 'Microsoft.VCLibs.140.00.UWPDesktop' -ErrorAction SilentlyContinue
            if (-not $vcLibs) {
                $vcLibsUrl = 'https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx'
                $vcLibsPath = Join-Path $env:TEMP 'Microsoft.VCLibs.x64.14.00.Desktop.appx'
                Invoke-WebRequest -Uri $vcLibsUrl -OutFile $vcLibsPath -UseBasicParsing
                Add-AppxPackage -Path $vcLibsPath -ErrorAction SilentlyContinue
            }
        } catch {
            Write-Log -Message "VCLibs dependency install issue: $($_.Exception.Message)" -Level 'WARN'
        }

        try {
            $uixamlUrl = 'https://github.com/microsoft/microsoft-ui-xaml/releases/download/v2.8.6/Microsoft.UI.Xaml.2.8.x64.appx'
            $uixamlPath = Join-Path $env:TEMP 'Microsoft.UI.Xaml.2.8.x64.appx'
            $existingXaml = Get-AppxPackage -Name 'Microsoft.UI.Xaml.2.8' -ErrorAction SilentlyContinue
            if (-not $existingXaml) {
                Invoke-WebRequest -Uri $uixamlUrl -OutFile $uixamlPath -UseBasicParsing
                Add-AppxPackage -Path $uixamlPath -ErrorAction SilentlyContinue
            }
        } catch {
            Write-Log -Message "UI.Xaml dependency install issue: $($_.Exception.Message)" -Level 'WARN'
        }

        $wingetUrl = 'https://aka.ms/getwinget'
        $wingetBundlePath = Join-Path $env:TEMP 'Microsoft.DesktopAppInstaller.msixbundle'
        Invoke-WebRequest -Uri $wingetUrl -OutFile $wingetBundlePath -UseBasicParsing
        Add-AppxPackage -Path $wingetBundlePath -ErrorAction Stop

        $ProgressPreference = $progressPref
    }
}

function Confirm-Winget {
    Write-Log -Message 'Validating Winget availability.'
    if (Test-WingetWorks) {
        Write-Log -Message 'Winget is present and functional.' -Level 'SUCCESS'
        return $true
    }

    Write-Log -Message 'Winget missing or broken. Attempting install/repair.' -Level 'WARN'
    Install-Winget

    Start-Sleep -Seconds 5
    $env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path', 'User')

    if (Test-WingetWorks) {
        Write-Log -Message 'Winget repaired successfully.' -Level 'SUCCESS'
        return $true
    }

    Add-Failure -Message 'Winget could not be installed or repaired. Application installs will be skipped.'
    return $false
}

function Install-WingetApp {
    param([Parameter(Mandatory = $true)][string]$PackageId)

    $wingetPath = Get-WingetPath
    if (-not $wingetPath) {
        Add-Failure -Message "Cannot install $PackageId - Winget not available."
        return
    }

    Invoke-SafeAction -Description "Install application: $PackageId" -Action {
        $arguments = @(
            'install',
            '--id', $PackageId,
            '--exact',
            '--silent',
            '--accept-package-agreements',
            '--accept-source-agreements',
            '--disable-interactivity',
            '--source', 'winget'
        )
        $proc = Start-Process -FilePath $wingetPath -ArgumentList $arguments -Wait -PassThru -NoNewWindow
        if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne -1978335189) {
            throw "Winget exited with code $($proc.ExitCode) for $PackageId"
        }
    }
}

function Uninstall-ByWinget {
    param([Parameter(Mandatory = $true)][string]$NameMatch)

    $wingetPath = Get-WingetPath
    if (-not $wingetPath) { return }

    try {
        $listOutput = & $wingetPath list --name $NameMatch --accept-source-agreements 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $listOutput) { return }

        $lines = $listOutput -split "`r?`n" | Where-Object { $_ -match $NameMatch }
        foreach ($line in $lines) {
            $tokens = ($line -split '\s{2,}')
            if ($tokens.Count -ge 2) {
                $appName = $tokens[0].Trim()
                if ($appName -and $appName -ne 'Name') {
                    try {
                        $args = @('uninstall', '--name', $appName, '--silent', '--accept-source-agreements', '--disable-interactivity', '--force')
                        Start-Process -FilePath $wingetPath -ArgumentList $args -Wait -NoNewWindow -ErrorAction Stop
                        Write-Log -Message "Uninstalled via winget: $appName" -Level 'SUCCESS'
                    } catch {
                        Write-Log -Message "Winget uninstall attempt failed for ${appName}: $($_.Exception.Message)" -Level 'WARN'
                    }
                }
            }
        }
    } catch {
        Write-Log -Message "Winget list/uninstall issue for pattern '$NameMatch': $($_.Exception.Message)" -Level 'WARN'
    }
}

function Remove-AppByAllMethods {
    param(
        [Parameter(Mandatory = $true)][string]$DisplayLabel,
        [Parameter(Mandatory = $true)][string]$WildcardPattern
    )

    Invoke-SafeAction -Description "Remove AppX package matching '$WildcardPattern'" -Action {
        $pkgs = Get-AppxPackage -AllUsers -Name "*$WildcardPattern*" -ErrorAction SilentlyContinue
        foreach ($pkg in $pkgs) {
            try {
                Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
                Write-Log -Message "Removed AppX: $($pkg.PackageFullName)" -Level 'SUCCESS'
            } catch {
                Add-Failure -Message "Failed removing AppX $($pkg.PackageFullName): $($_.Exception.Message)"
            }
        }

        $provisioned = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like "*$WildcardPattern*" }
        foreach ($p in $provisioned) {
            try {
                Remove-AppxProvisionedPackage -Online -PackageName $p.PackageName -ErrorAction Stop | Out-Null
                Write-Log -Message "Removed provisioned: $($p.PackageName)" -Level 'SUCCESS'
            } catch {
                Add-Failure -Message "Failed removing provisioned $($p.PackageName): $($_.Exception.Message)"
            }
        }
    }

    $uninstallRoots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    Invoke-SafeAction -Description "Uninstall registry product matching '$WildcardPattern'" -Action {
        foreach ($root in $uninstallRoots) {
            $keys = Get-ItemProperty -Path $root -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like "*$WildcardPattern*" }
            foreach ($key in $keys) {
                try {
                    if ($key.QuietUninstallString) {
                        Start-Process -FilePath 'cmd.exe' -ArgumentList "/c $($key.QuietUninstallString)" -Wait -ErrorAction SilentlyContinue
                        Write-Log -Message "Uninstalled (quiet string): $($key.DisplayName)" -Level 'SUCCESS'
                    } elseif ($key.UninstallString) {
                        if ($key.UninstallString -match 'msiexec') {
                            $productCode = ($key.UninstallString | Select-String -Pattern '\{[0-9A-Fa-f\-]+\}').Matches.Value
                            if ($productCode) {
                                Start-Process -FilePath 'msiexec.exe' -ArgumentList "/x $productCode /qn /norestart" -Wait -ErrorAction Stop
                            }
                        } else {
                            $exePath = $key.UninstallString -replace '"', ''
                            Start-Process -FilePath $exePath -ArgumentList '/S /silent /verysilent /norestart /quiet' -Wait -ErrorAction SilentlyContinue
                        }
                        Write-Log -Message "Uninstalled: $($key.DisplayName)" -Level 'SUCCESS'
                    }
                } catch {
                    Add-Failure -Message "Failed uninstalling $($key.DisplayName): $($_.Exception.Message)"
                }
            }
        }
    }

    Invoke-SafeAction -Description "Uninstall via winget matching '$WildcardPattern'" -Action {
        Uninstall-ByWinget -NameMatch $WildcardPattern
    }
}

function Install-CorporateApplications {
    Write-Log -Message 'Beginning application installation phase.'
    $apps = @(
        'Google.Chrome',
        'VideoLAN.VLC',
        'Microsoft.PowerShell',
        'TeamViewer.TeamViewerHost'
    )
    foreach ($app in $apps) {
        Install-WingetApp -PackageId $app
    }
}

# ============================================================
# NEW OUTLOOK REMOVAL (KEEP CLASSIC OUTLOOK)
# ============================================================

function Remove-NewOutlook {
    Invoke-SafeAction -Description 'Remove New Outlook Appx packages' -Action {
        $pkgs = Get-AppxPackage -AllUsers -Name '*Microsoft.OutlookForWindows*' -ErrorAction SilentlyContinue
        foreach ($pkg in $pkgs) {
            try {
                Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
                Write-Log -Message "Removed New Outlook package: $($pkg.PackageFullName)" -Level 'SUCCESS'
            } catch {
                Add-Failure -Message "Failed removing New Outlook package $($pkg.PackageFullName): $($_.Exception.Message)"
            }
        }
    }

    Invoke-SafeAction -Description 'Remove New Outlook provisioned packages' -Action {
        $provisioned = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like '*OutlookForWindows*' }
        foreach ($p in $provisioned) {
            try {
                Remove-AppxProvisionedPackage -Online -PackageName $p.PackageName -ErrorAction Stop | Out-Null
                Write-Log -Message "Removed provisioned New Outlook package: $($p.PackageName)" -Level 'SUCCESS'
            } catch {
                Add-Failure -Message "Failed removing provisioned New Outlook package $($p.PackageName): $($_.Exception.Message)"
            }
        }
    }
    Write-Log -Message 'Classic Outlook (Office desktop) preserved - not touched by this routine.'
}

# ============================================================
# BLOAT REMOVAL - MICROSOFT
# ============================================================

function Remove-MicrosoftBloat {
    Write-Log -Message 'Beginning Microsoft consumer bloat removal.'

    $bloatPatterns = @(
        'Microsoft.XboxApp',
        'Microsoft.XboxGameOverlay',
        'Microsoft.XboxGamingOverlay',
        'Microsoft.XboxIdentityProvider',
        'Microsoft.XboxSpeechToTextOverlay',
        'Microsoft.Xbox.TCUI',
        'Microsoft.GamingApp',
        'Microsoft.GamingServices',
        'Microsoft.MicrosoftSolitaireCollection',
        'BytedancePte.Ltd.TikTok',
        'SpotifyAB.SpotifyMusic',
        'NetflixInc.Netflix',
        'Facebook.InstagramforWindows',
        'Facebook.Facebook',
        'Disney.37853FC22B2CE',
        'Microsoft.SkypeApp',
        'MicrosoftTeams',
        'microsoft.windowscommunicationsapps',
        'Microsoft.BingNews',
        'MicrosoftWindows.Client.WebExperience',
        'Microsoft.Windows.Ai.Copilot.Provider',
        'Microsoft.People',
        'Microsoft.MixedReality.Portal',
        'Microsoft.GetHelp',
        'Microsoft.Getstarted',
        'Microsoft.549981C3F5F10'
    )

    foreach ($pattern in $bloatPatterns) {
        Remove-AppByAllMethods -DisplayLabel 'Microsoft' -WildcardPattern $pattern
    }

    Invoke-SafeAction -Description 'Disable Widgets board' -Action {
        $widgetPkg = Get-AppxPackage -AllUsers -Name 'MicrosoftWindows.Client.WebExperience' -ErrorAction SilentlyContinue
        if ($widgetPkg) {
            Remove-AppxPackage -Package $widgetPkg.PackageFullName -AllUsers -ErrorAction SilentlyContinue
        }
        $regPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh'
        if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
        Set-ItemProperty -Path $regPath -Name 'AllowNewsAndInterests' -Value 0 -Type DWord -Force
    }

    Invoke-SafeAction -Description 'Disable Gaming Services related tasks' -Action {
        Get-ScheduledTask -TaskName '*Gaming*' -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                Disable-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath -ErrorAction SilentlyContinue | Out-Null
            } catch { }
        }
    }

    Write-Log -Message 'Preserving: Clipchamp, Calculator, Paint, Photos, Notepad, Snipping Tool, Windows Terminal, Teams Work.'
}

# ============================================================
# DELL CLEANUP
# ============================================================

function Remove-DellBloat {
    Write-Log -Message 'Beginning Dell bloatware removal.'

    $dellPatterns = @(
        'DellInc.DellSupportAssistforPCs',
        'DellInc.DellOptimizer',
        'DellInc.DellDigitalDelivery',
        'DellInc.PartnerPromo',
        'DellInc.DellCustomerConnect',
        'DellInc.DellCommandUpdate',
        'DellInc.MyDell',
        'DellInc.DellPairing',
        'Dell SupportAssist',
        'Dell Optimizer',
        'Dell Digital Delivery',
        'Dell Pair',
        'Dell Customer Connect',
        'Dell Command',
        'Dell Update',
        'My Dell',
        'Dell Display Manager',
        'Dell Peripheral Manager',
        'Dell Mobile Connect',
        'SmartByte',
        'ExpressConnect'
    )

    foreach ($pattern in $dellPatterns) {
        Remove-AppByAllMethods -DisplayLabel 'Dell' -WildcardPattern $pattern
    }
}

# ============================================================
# LENOVO CLEANUP
# ============================================================

function Remove-LenovoBloat {
    Write-Log -Message 'Beginning Lenovo bloatware removal.'

    $lenovoPatterns = @(
        'E046963F.LenovoCompanion',
        'E046963F.LenovoSettingsforEnterprise',
        'E046963F.LenovoUtility',
        'E046963F.LenovoSmartAppearance',
        'LenovoCorporation.LenovoVantage',
        'E046963F',
        'Lenovo Welcome',
        'Lenovo App Explorer',
        'Lenovo Service Bridge',
        'Lenovo Utility',
        'Lenovo Vantage',
        'Lenovo Now',
        'Lenovo Pen Settings',
        'Lenovo Smart Meeting',
        'Lenovo Smart Appearance',
        'Lenovo Smart Noise Cancellation',
        'MemcMFT'
    )

    foreach ($pattern in $lenovoPatterns) {
        Remove-AppByAllMethods -DisplayLabel 'Lenovo' -WildcardPattern $pattern
    }
}

# ============================================================
# THIRD-PARTY ANTIVIRUS CLEANUP (McAfee / Trend Micro / AVG / Norton)
# ============================================================

function Stop-AntivirusServices {
    $avServicePatterns = @(
        'McAfee*', 'mfe*', 'masvc*', 'McShield*',
        'Trend Micro*', 'tmlisten*', 'ntrtscan*', 'tmproxy*',
        'AVG*', 'avg*',
        'Norton*', 'Symantec*', 'NortonSecurity*', 'ccSvcHst*'
    )
    foreach ($pattern in $avServicePatterns) {
        Get-Service -Name $pattern -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                Stop-Service -Name $_.Name -Force -ErrorAction SilentlyContinue
                Set-Service -Name $_.Name -StartupType Disabled -ErrorAction SilentlyContinue
                Write-Log -Message "Stopped and disabled AV service: $($_.Name)" -Level 'SUCCESS'
            } catch {
                Write-Log -Message "Non-fatal issue stopping service $($_.Name): $($_.Exception.Message)" -Level 'WARN'
            }
        }
    }
}

function Remove-AntivirusBloat {
    Write-Log -Message 'Beginning third-party antivirus removal (McAfee, Trend Micro, AVG, Norton).'

    Stop-AntivirusServices

    $avPatterns = @(
        'McAfee',
        'WebAdvisor',
        'TrendMicro',
        'Trend Micro',
        'AVG',
        'Norton',
        'NortonSecurity',
        'Norton 360',
        'Symantec'
    )

    foreach ($pattern in $avPatterns) {
        Remove-AppByAllMethods -DisplayLabel 'Antivirus' -WildcardPattern $pattern
    }

    Invoke-SafeAction -Description 'Run McAfee Consumer Product Removal tool (MCPR) if present' -Action {
        $mcprPaths = @(
            "$env:ProgramFiles\McAfee\MCPR\mcpr.exe",
            "$env:ProgramData\McAfee\MCPR\mcpr.exe"
        )
        $mcpr = $mcprPaths | Where-Object { Test-Path $_ } | Select-Object -First 1
        if ($mcpr) {
            Start-Process -FilePath $mcpr -ArgumentList '-silent' -Wait -ErrorAction SilentlyContinue
            Write-Log -Message 'Ran local MCPR removal tool.' -Level 'SUCCESS'
        } else {
            Write-Log -Message 'MCPR tool not found locally - skipped (standard uninstall path used instead).'
        }
    }

    Invoke-SafeAction -Description 'Run Norton Remove and Reinstall tool (NRnR) if present' -Action {
        $nrnrPaths = @(
            "$env:ProgramFiles\Norton Security\Engine\*\NRnR.exe",
            "$env:ProgramFiles(x86)\Norton Security\Engine\*\NRnR.exe"
        )
        $nrnr = $nrnrPaths | ForEach-Object { Get-Item -Path $_ -ErrorAction SilentlyContinue } | Select-Object -First 1
        if ($nrnr) {
            Start-Process -FilePath $nrnr.FullName -ArgumentList '/silent' -Wait -ErrorAction SilentlyContinue
            Write-Log -Message 'Ran local Norton NRnR removal tool.' -Level 'SUCCESS'
        } else {
            Write-Log -Message 'NRnR tool not found locally - skipped (standard uninstall path used instead).'
        }
    }

    Write-Log -Message 'Third-party antivirus removal pass complete.'
}

# ============================================================
# AUSTRALIA REGIONAL CONFIGURATION
# ============================================================

function Set-AustraliaRegion {
    Invoke-SafeAction -Description 'Set system region and locale to Australia (en-AU)' -Action {
        Set-WinHomeLocation -GeoId 12
        Set-WinSystemLocale -SystemLocale 'en-AU'
        Set-WinUILanguageOverride -Language 'en-AU'
        Set-Culture -CultureInfo 'en-AU'
    }

    Invoke-SafeAction -Description 'Set input/keyboard to en-AU' -Action {
        $languageList = New-WinUserLanguageList -Language 'en-AU'
        Set-WinUserLanguageList -LanguageList $languageList -Force
    }

    Invoke-SafeAction -Description 'Set timezone to AUS Eastern Standard Time' -Action {
        Set-TimeZone -Id 'AUS Eastern Standard Time'
    }

    Invoke-SafeAction -Description 'Set regional format (currency, date, short date) to en-AU' -Action {
        $intlRegPath = 'HKCU:\Control Panel\International'
        Set-ItemProperty -Path $intlRegPath -Name 'sCurrency' -Value '$' -Force
        Set-ItemProperty -Path $intlRegPath -Name 'sShortDate' -Value 'dd/MM/yyyy' -Force
        Set-ItemProperty -Path $intlRegPath -Name 'sLongDate' -Value 'dddd, d MMMM yyyy' -Force
        Set-ItemProperty -Path $intlRegPath -Name 'sCountry' -Value 'Australia' -Force
        Set-ItemProperty -Path $intlRegPath -Name 'iCountry' -Value '61' -Force
        Set-ItemProperty -Path $intlRegPath -Name 'sLanguage' -Value 'ENA' -Force
        Set-ItemProperty -Path $intlRegPath -Name 'Locale' -Value '00000C09' -Force
        Set-ItemProperty -Path $intlRegPath -Name 'LocaleName' -Value 'en-AU' -Force
        Set-ItemProperty -Path $intlRegPath -Name 'sCurrencySymbol' -Value 'AUD' -Force -ErrorAction SilentlyContinue
    }

    Invoke-SafeAction -Description 'Remove US regional artifacts where possible' -Action {
        try {
            $currentList = Get-WinUserLanguageList
            $usEntries = $currentList | Where-Object { $_.LanguageTag -eq 'en-US' }
            if ($usEntries) {
                foreach ($entry in $usEntries) { $currentList.Remove($entry) | Out-Null }
                if ($currentList.Count -eq 0) {
                    $currentList = New-WinUserLanguageList -Language 'en-AU'
                }
                Set-WinUserLanguageList -LanguageList $currentList -Force
            }
        } catch {
            Write-Log -Message "Non-fatal issue removing en-US language entries: $($_.Exception.Message)" -Level 'WARN'
        }
    }
}

# ============================================================
# WINDOWS UPDATE CONFIGURATION
# ============================================================

function Set-WindowsUpdatePolicies {
    Invoke-SafeAction -Description 'Configure Windows Update: receive updates for other Microsoft products' -Action {
        $svcPath = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
        if (-not (Test-Path $svcPath)) { New-Item -Path $svcPath -Force | Out-Null }

        try {
            $serviceManager = New-Object -ComObject Microsoft.Update.ServiceManager -ErrorAction Stop
            $serviceManager.AddService2('7971f918-a847-4430-9279-4a52d1efe18d', 7, '') | Out-Null
        } catch {
            Write-Log -Message "Microsoft Update service registration non-fatal issue: $($_.Exception.Message)" -Level 'WARN'
        }
    }

    Invoke-SafeAction -Description 'Configure Windows Update: get me up to date / get latest updates as soon as available' -Action {
        $auPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\UX\Settings'
        if (-not (Test-Path $auPath)) { New-Item -Path $auPath -Force | Out-Null }
        Set-ItemProperty -Path $auPath -Name 'IsContinuousInnovationOptedIn' -Value 1 -Type DWord -Force
        Set-ItemProperty -Path $auPath -Name 'AllowAutoWindowsUpdateDownloadOverMeteredNetwork' -Value 1 -Type DWord -Force

        $wuPolicyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
        if (-not (Test-Path $wuPolicyPath)) { New-Item -Path $wuPolicyPath -Force | Out-Null }
        Set-ItemProperty -Path $wuPolicyPath -Name 'NoAutoUpdate' -Value 0 -Type DWord -Force
        Set-ItemProperty -Path $wuPolicyPath -Name 'AUOptions' -Value 4 -Type DWord -Force
    }

    Invoke-SafeAction -Description 'Configure Windows Update: allow download over metered networks' -Action {
        $meteredPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\UX\Settings'
        if (-not (Test-Path $meteredPath)) { New-Item -Path $meteredPath -Force | Out-Null }
        Set-ItemProperty -Path $meteredPath -Name 'AllowAutoWindowsUpdateDownloadOverMeteredNetwork' -Value 1 -Type DWord -Force
    }

    Invoke-SafeAction -Description 'Enable driver updates via Windows Update' -Action {
        $driverPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching'
        if (-not (Test-Path $driverPath)) { New-Item -Path $driverPath -Force | Out-Null }
        Set-ItemProperty -Path $driverPath -Name 'SearchOrderConfig' -Value 1 -Type DWord -Force

        $deviceMetadataPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata'
        if (-not (Test-Path $deviceMetadataPath)) { New-Item -Path $deviceMetadataPath -Force | Out-Null }
        Set-ItemProperty -Path $deviceMetadataPath -Name 'PreventDeviceMetadataFromNetwork' -Value 0 -Type DWord -Force
    }
}

function Install-PSWindowsUpdateModule {
    Invoke-SafeAction -Description 'Ensure NuGet provider and PSGallery trust' -Action {
        try {
            if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
                Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers | Out-Null
            }
        } catch {
            Write-Log -Message "NuGet provider install non-fatal issue: $($_.Exception.Message)" -Level 'WARN'
        }
        try {
            Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted -ErrorAction SilentlyContinue
        } catch { }
    }

    Invoke-SafeAction -Description 'Install PSWindowsUpdate module' -Action {
        if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
            Install-Module -Name PSWindowsUpdate -Force -Scope AllUsers -AllowClobber -ErrorAction Stop
        }
        Import-Module -Name PSWindowsUpdate -Force -ErrorAction Stop
    }
}

function Invoke-WindowsUpdateLoop {
    $maxPasses = 5
    $rebootRequired = $false

    if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
        Add-Failure -Message 'PSWindowsUpdate module unavailable - skipping update scan/install loop.'
        return $rebootRequired
    }

    for ($pass = 1; $pass -le $maxPasses; $pass++) {
        Write-Log -Message "Windows Update pass ${pass} of $maxPasses starting."
        $passHadUpdates = $false

        try {
            $updates = Get-WindowsUpdate -MicrosoftUpdate -AcceptAll -IgnoreReboot -ErrorAction Stop `
                -Category 'Critical Updates', 'Security Updates', 'Update Rollups', 'Updates', 'Feature Packs', 'Definition Updates', 'Drivers', 'Service Packs' -ErrorAction SilentlyContinue

            if ($updates -and $updates.Count -gt 0) {
                $passHadUpdates = $true
                Write-Log -Message "Pass ${pass}: $($updates.Count) update(s) found. Installing."

                $result = Install-WindowsUpdate -MicrosoftUpdate -AcceptAll -IgnoreReboot -Install -ErrorAction Stop -Verbose:$false

                foreach ($r in $result) {
                    if ($r.RebootRequired) { $rebootRequired = $true }
                }
                Write-Log -Message "Pass ${pass} complete: installed available updates." -Level 'SUCCESS'
            } else {
                Write-Log -Message "Pass ${pass}: no updates found. Loop complete."
            }
        } catch {
            Add-Failure -Message "Windows Update pass ${pass} failed: $($_.Exception.Message)"
        }

        if (Get-Command -Name Get-WURebootStatus -ErrorAction SilentlyContinue) {
            try {
                $rebootStatus = Get-WURebootStatus -Silent -ErrorAction SilentlyContinue
                if ($rebootStatus) { $rebootRequired = $true }
            } catch { }
        }

        if (-not $passHadUpdates) { break }
    }

    return $rebootRequired
}

# ============================================================
# OUTLOOK / ONEDRIVE SSO
# ============================================================

function Set-OutlookSSO {
    Invoke-SafeAction -Description 'Configure Outlook SSO (EnableADAL / DisableAADWAM)' -Action {
        $officeIdentityPath = 'HKCU:\SOFTWARE\Microsoft\Office\16.0\Common\Identity'
        if (-not (Test-Path $officeIdentityPath)) { New-Item -Path $officeIdentityPath -Force | Out-Null }
        Set-ItemProperty -Path $officeIdentityPath -Name 'EnableADAL' -Value 1 -Type DWord -Force
        Set-ItemProperty -Path $officeIdentityPath -Name 'DisableAADWAM' -Value 0 -Type DWord -Force

        $officeIdentityPathMachine = 'HKLM:\SOFTWARE\Policies\Microsoft\Office\16.0\Common\Identity'
        if (-not (Test-Path $officeIdentityPathMachine)) { New-Item -Path $officeIdentityPathMachine -Force | Out-Null }
        Set-ItemProperty -Path $officeIdentityPathMachine -Name 'EnableADAL' -Value 1 -Type DWord -Force
        Set-ItemProperty -Path $officeIdentityPathMachine -Name 'DisableAADWAM' -Value 0 -Type DWord -Force
    }
}

function Set-OneDriveSSO {
    Invoke-SafeAction -Description 'Configure OneDrive SilentAccountConfig SSO' -Action {
        $oneDrivePath = 'HKLM:\SOFTWARE\Policies\Microsoft\OneDrive'
        if (-not (Test-Path $oneDrivePath)) { New-Item -Path $oneDrivePath -Force | Out-Null }
        Set-ItemProperty -Path $oneDrivePath -Name 'SilentAccountConfig' -Value 1 -Type DWord -Force
    }
}

# ============================================================
# END OF SCRIPT - LAUNCH PROMPT
# ============================================================

function Get-DetectedUser {
    try {
        $upn = whoami /upn 2>$null
        if ($upn -and $upn.Trim() -ne '') { return $upn.Trim() }
    } catch { }
    return "$env:USERDOMAIN\$env:USERNAME"
}

function Invoke-LaunchPrompt {
    param([Parameter(Mandatory = $true)][string]$DetectedUser)

    Write-Host ''
    Write-Host 'Detected User:'
    Write-Host $DetectedUser
    Write-Host ''

    $response = Read-Host -Prompt 'Launch Outlook and OneDrive now? Y/N'

    if ($response -match '^(?i)y') {
        Invoke-SafeAction -Description 'Launch OneDrive' -Action {
            $oneDriveExe = Join-Path $env:LOCALAPPDATA 'Microsoft\OneDrive\OneDrive.exe'
            if (Test-Path $oneDriveExe) {
                Start-Process -FilePath $oneDriveExe
            } else {
                throw 'OneDrive executable not found.'
            }
        }

        Invoke-SafeAction -Description 'Launch Outlook (if installed)' -Action {
            $outlookPaths = @(
                "$env:ProgramFiles\Microsoft Office\root\Office16\OUTLOOK.EXE",
                "${env:ProgramFiles(x86)}\Microsoft Office\root\Office16\OUTLOOK.EXE"
            )
            $found = $outlookPaths | Where-Object { Test-Path $_ } | Select-Object -First 1
            if ($found) {
                Start-Process -FilePath $found
            } else {
                Write-Log -Message 'Classic Outlook executable not found - skipping launch.' -Level 'WARN'
            }
        }
    } else {
        Write-Log -Message 'User declined to launch Outlook/OneDrive.'
    }
}

# ============================================================
# BUILD REPORT
# ============================================================

function New-BuildReport {
    param([bool]$RebootRequired)

    $computerName = $env:COMPUTERNAME
    $loggedInUser = "$env:USERDOMAIN\$env:USERNAME"
    $manufacturer = 'Unknown'
    $model = 'Unknown'
    $serial = 'Unknown'

    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $manufacturer = $cs.Manufacturer
        $model = $cs.Model
    } catch {
        Add-Failure -Message "Failed retrieving computer system info: $($_.Exception.Message)"
    }

    try {
        $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop
        $serial = $bios.SerialNumber
    } catch {
        Add-Failure -Message "Failed retrieving serial number: $($_.Exception.Message)"
    }

    $buildDate = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $duration = (Get-Date) - $Script:BuildStart

    $reportLines = New-Object System.Collections.Generic.List[string]
    $reportLines.Add('==================================================')
    $reportLines.Add('           CORPORATE BUILD REPORT')
    $reportLines.Add('==================================================')
    $reportLines.Add("Computer Name    : $computerName")
    $reportLines.Add("Manufacturer     : $manufacturer")
    $reportLines.Add("Model            : $model")
    $reportLines.Add("Serial Number    : $serial")
    $reportLines.Add("Logged In User   : $loggedInUser")
    $reportLines.Add("Build Date       : $buildDate")
    $reportLines.Add("Build Duration   : $($duration.ToString('hh\:mm\:ss'))")
    $reportLines.Add("Reboot Required  : $RebootRequired")
    $reportLines.Add('')
    $reportLines.Add('--------------------------------------------------')
    $reportLines.Add('FAILURES')
    $reportLines.Add('--------------------------------------------------')

    if ($Script:Failures.Count -eq 0) {
        $reportLines.Add('None. Build completed without failures.')
    } else {
        $i = 1
        foreach ($failure in $Script:Failures) {
            $reportLines.Add("$i. $failure")
            $i++
        }
    }

    $reportLines.Add('==================================================')

    try {
        Set-Content -Path $Script:ReportPath -Value $reportLines -Force -ErrorAction Stop
        Write-Log -Message "Build report written to $Script:ReportPath" -Level 'SUCCESS'
    } catch {
        Write-Log -Message "Failed to write build report: $($_.Exception.Message)" -Level 'ERROR'
    }
}

# ============================================================
# MAIN EXECUTION
# ============================================================

function Start-CorporateBuild {
    Initialize-Environment
    Write-Log -Message '================ CorporateBuild.ps1 STARTED ================'

    Confirm-Environment

    $wingetReady = Confirm-Winget
    if ($wingetReady) {
        Install-CorporateApplications
    } else {
        Add-Failure -Message 'Skipped application installation phase - Winget not available.'
    }

    Remove-NewOutlook
    Remove-MicrosoftBloat
    Remove-DellBloat
    Remove-LenovoBloat
    Remove-AntivirusBloat

    Set-AustraliaRegion

    Set-WindowsUpdatePolicies
    Install-PSWindowsUpdateModule
    $rebootRequired = Invoke-WindowsUpdateLoop

    Set-OutlookSSO
    Set-OneDriveSSO

    New-BuildReport -RebootRequired $rebootRequired

    Write-Log -Message '================ CorporateBuild.ps1 COMPLETE ================'

    $detectedUser = Get-DetectedUser
    Invoke-LaunchPrompt -DetectedUser $detectedUser

    if ($rebootRequired) {
        Write-Host ''
        Write-Host 'A reboot is required to complete Windows Updates.'
        $rebootResponse = Read-Host -Prompt 'Reboot now? Y/N'
        if ($rebootResponse -match '^(?i)y') {
            Write-Log -Message 'User confirmed reboot. Restarting computer.'
            Restart-Computer -Force
        } else {
            Write-Log -Message 'User declined immediate reboot. Reboot pending.'
        }
    }

    if ($Script:Failures.Count -gt 0) {
        Write-Host ''
        Write-Host "Build completed with $($Script:Failures.Count) failure(s). See $Script:ReportPath and $Script:LogPath for details." -ForegroundColor Yellow
    } else {
        Write-Host ''
        Write-Host 'Build completed successfully with no failures.' -ForegroundColor Green
    }
}

Start-CorporateBuild
