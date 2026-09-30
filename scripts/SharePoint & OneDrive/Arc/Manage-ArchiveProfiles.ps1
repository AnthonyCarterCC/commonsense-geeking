#Requires -Modules PnP.PowerShell
<#
.SYNOPSIS
    Interactive wizard for creating/editing per-client archive profiles (JSON
    config files) and running the archive toolset against them - no manual
    JSON copy/paste/editing required.

.DESCRIPTION
    - Lists existing profiles (JSON files) in this folder; pick one to load
      and reuse, or create a new one from prompts (each prompt shows the
      current/default value in brackets - press Enter to keep it).
    - Keeps a local registry (app-registry.json) of every ClientId/Thumbprint
      pairing it has ever created or confirmed, per tenant. This is what
      makes the [L]ist and [D]elete options below possible - a certificate
      sitting in the Windows cert store doesn't carry its Entra ClientId with
      it, so without remembering that pairing ourselves there'd be no way to
      show it back to you later.
    - Before creating a NEW profile, checks the registry (and, for backward
      compatibility, other saved profiles) for a usable app + certificate for
      that tenant. If more than one is found, you choose which to use. If
      nothing usable is found, it registers a new Entra app + certificate for
      you (Register-PnPEntraIDApp), walks you through granting consent, and
      offers to export a portable .pfx (named after the profile) so the same
      cert can be reused on another machine later without re-registering.
    - [L] from the main menu lists every certificate this tool knows about on
      this machine, and which profile (if any) currently uses each one.
    - [D] from the main menu deletes certificates/registry entries you no
      longer need - it will not delete anything a saved profile still
      references unless you explicitly confirm.
    - Once a profile is active, a menu lets you run any of the toolset
      scripts against it (archive, reconciliation check, rename cleanup,
      cold-storage archive) without typing the -ConfigPath commands by hand.

.NOTES
    This is a thin wrapper - all the actual archiving/renaming/checking logic
    still lives in the other scripts in this folder. This just manages the
    JSON profiles and calls them for you.
#>

$folder = $PSScriptRoot
$ErrorActionPreference = "Stop"
$registryPath = Join-Path $folder "app-registry.json"

function Read-WithDefault {
    param([string]$Prompt, [string]$Default = "")
    if ($Default -ne "") {
        $val = Read-Host "$Prompt [$Default]"
        if ([string]::IsNullOrWhiteSpace($val)) { return $Default }
        return $val
    }
    return Read-Host $Prompt
}

# ---------------------------------------------------------------------------
# Local registry of every ClientId/Thumbprint pairing this tool has created
# or confirmed. A certificate alone (in Cert:\CurrentUser\My) doesn't carry
# its Entra ClientId with it, so this is the only way to reliably list or
# clean these up later instead of re-deriving them from scratch each time.
# ---------------------------------------------------------------------------
function Get-AppRegistry {
    if (-not (Test-Path $registryPath)) { return @() }
    try {
        $data = Get-Content $registryPath -Raw | ConvertFrom-Json
        if ($null -eq $data) { return @() }
        return @($data)
    } catch { return @() }
}

function Save-AppRegistry {
    param([array]$Entries)
    ($Entries | ConvertTo-Json -Depth 5) | Set-Content -Path $registryPath -Encoding UTF8
}

function Add-AppRegistryEntry {
    param([string]$Tenant, [string]$AppName, [string]$ClientId, [string]$Thumbprint)
    $entries = @(Get-AppRegistry | Where-Object { $_.Thumbprint -ne $Thumbprint })
    $entries += [PSCustomObject]@{
        Tenant     = $Tenant
        AppName    = $AppName
        ClientId   = $ClientId
        Thumbprint = $Thumbprint
        Recorded   = (Get-Date).ToString("s")
    }
    Save-AppRegistry -Entries $entries
}

function Get-ProfilesUsingThumbprint {
    param([string]$Thumbprint)
    Get-ChildItem -Path $folder -Filter "*.json" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch 'template' -and $_.Name -ne 'app-registry.json' } |
        ForEach-Object {
            try {
                $c = Get-Content $_.FullName -Raw | ConvertFrom-Json
                if ($c.Thumbprint -eq $Thumbprint) { $_.Name }
            } catch {}
        }
}

function Get-ExistingAppClientId {
    # Looks up an existing Entra app registration's AppId (ClientId) by name
    # via Microsoft Graph - used when Register-PnPEntraIDApp fails because the
    # app already exists, so we can attach a fresh certificate to it instead
    # of asking the user to delete/recreate it or upload a .cer by hand.
    param([string]$AppName, [string]$Tenant)
    try {
        if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Applications)) {
            Write-Host "Installing Microsoft.Graph.Applications module (one-time)..." -ForegroundColor Yellow
            Install-Module Microsoft.Graph.Applications -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
        }
        Import-Module Microsoft.Graph.Applications -ErrorAction Stop
        if (-not (Get-MgContext)) {
            Write-Host "Signing in as Global Admin for $Tenant (Graph, Application.ReadWrite.All) - this is a one-time browser sign-in, same as the app registration step." -ForegroundColor Cyan
            Connect-MgGraph -Scopes "Application.ReadWrite.All" -TenantId $Tenant -NoWelcome -ErrorAction Stop
        }
        $app = @(Get-MgApplication -Filter "displayName eq '$AppName'" -ErrorAction Stop)
        if ($app.Count -eq 1) { return $app[0] }
        Write-Host "Expected exactly one app named '$AppName' in Entra, found $($app.Count) - resolve manually in the portal." -ForegroundColor Red
        return $null
    } catch {
        Write-Host "Couldn't look up '$AppName' via Graph: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
}

function Add-CertificateToEntraApp {
    # Attaches a certificate already sitting in the local cert store to an
    # EXISTING Entra app registration via Microsoft Graph - the automated
    # equivalent of the manual "Certificates & secrets > Upload certificate"
    # portal step. Preserves any certificates already attached to the app
    # (Update-MgApplication replaces the whole KeyCredentials set, so existing
    # ones must be included alongside the new one, not just the new one alone).
    param($App, [string]$Thumbprint)
    try {
        $cert = Get-ChildItem "Cert:\CurrentUser\My\$Thumbprint" -ErrorAction Stop
        $newKey = @{
            type        = "AsymmetricX509Cert"
            usage       = "Verify"
            key         = $cert.RawData
            displayName = "Added by Manage-ArchiveProfiles $(Get-Date -Format 'yyyy-MM-dd')"
        }
        $existingKeys = @($App.KeyCredentials)
        Update-MgApplication -ApplicationId $App.Id -KeyCredentials ($existingKeys + $newKey) -ErrorAction Stop
        Write-Host "Certificate $Thumbprint attached to '$($App.DisplayName)' via Graph - no portal upload needed." -ForegroundColor Green
        return $true
    } catch {
        Write-Host "Failed to attach certificate via Graph: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

function Get-ClientAppCredentials {
    param([string]$Tenant, [string]$FolderPath, [string]$ProfileBaseName)

    # 1. Check the registry first - every pairing this tool has ever created
    #    or confirmed for this tenant, filtered to ones still actually
    #    installed on this machine.
    $candidates = @(Get-AppRegistry | Where-Object { $_.Tenant -eq $Tenant } | ForEach-Object {
        $certOnDisk = Get-ChildItem "Cert:\CurrentUser\My\$($_.Thumbprint)" -ErrorAction SilentlyContinue
        if ($certOnDisk) { $_ }
    })

    if ($candidates.Count -eq 1) {
        Write-Host "Found an existing app + certificate for $Tenant in the registry - reusing it." -ForegroundColor Green
        return [PSCustomObject]@{ ClientId = $candidates[0].ClientId; Thumbprint = $candidates[0].Thumbprint }
    }
    if ($candidates.Count -gt 1) {
        Write-Host "`nMultiple known app/certificate pairs exist for $Tenant - pick one:" -ForegroundColor Yellow
        for ($i = 0; $i -lt $candidates.Count; $i++) {
            Write-Host "  [$($i + 1)] $($candidates[$i].AppName)  ClientId=$($candidates[$i].ClientId)  Thumbprint=$($candidates[$i].Thumbprint)"
        }
        Write-Host "  [N] None of these - register a new one"
        $pick = Read-Host "Choice"
        if ($pick -match '^\d+$' -and [int]$pick -ge 1 -and [int]$pick -le $candidates.Count) {
            $chosen = $candidates[[int]$pick - 1]
            return [PSCustomObject]@{ ClientId = $chosen.ClientId; Thumbprint = $chosen.Thumbprint }
        }
        # otherwise fall through to registering a new one
    }

    # 2. Backward compatibility - profiles created before the registry
    #    existed (e.g. the original Platinum profiles) won't be in it yet.
    #    Fall back to scanning other saved profiles for a matching tenant.
    $existingProfiles = Get-ChildItem -Path $FolderPath -Filter "*.json" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch 'template' -and $_.Name -ne 'app-registry.json' }
    foreach ($f in $existingProfiles) {
        try { $c = Get-Content $f.FullName -Raw | ConvertFrom-Json } catch { continue }
        if ($c.Tenant -eq $Tenant -and $c.ClientId -and $c.Thumbprint) {
            $certOnDisk = Get-ChildItem "Cert:\CurrentUser\My\$($c.Thumbprint)" -ErrorAction SilentlyContinue
            if ($certOnDisk) {
                Write-Host "Found an existing app + certificate for $Tenant (from $($f.Name)) - reusing it." -ForegroundColor Green
                Add-AppRegistryEntry -Tenant $Tenant -AppName "(unknown - pre-dates registry)" -ClientId $c.ClientId -Thumbprint $c.Thumbprint
                return [PSCustomObject]@{ ClientId = $c.ClientId; Thumbprint = $c.Thumbprint }
            }

            Write-Host "Found a profile for $Tenant ($($f.Name)), but its certificate isn't installed on this machine." -ForegroundColor Yellow
            $pfxPath = Join-Path $FolderPath "$($f.BaseName)-cert.pfx"
            if (Test-Path $pfxPath) {
                Write-Host "Found $pfxPath - importing it onto this machine..." -ForegroundColor Yellow
                $securePwd = Read-Host "Enter the .pfx password" -AsSecureString
                Import-PfxCertificate -FilePath $pfxPath -CertStoreLocation Cert:\CurrentUser\My -Password $securePwd | Out-Null
                Write-Host "Certificate imported." -ForegroundColor Green
                Add-AppRegistryEntry -Tenant $Tenant -AppName "(unknown - pre-dates registry)" -ClientId $c.ClientId -Thumbprint $c.Thumbprint
                return [PSCustomObject]@{ ClientId = $c.ClientId; Thumbprint = $c.Thumbprint }
            }
            Write-Host "No portable .pfx found either ($pfxPath) - will register a new app instead." -ForegroundColor Yellow
        }
    }

    # 3. Nothing usable - register a new app + certificate for this tenant.
    Write-Host "`nNo usable app/certificate found for $Tenant - registering a new one now." -ForegroundColor Cyan
    Write-Host "A browser window will open - sign in as a Global Admin for $Tenant." -ForegroundColor Yellow
    Read-Host "Press Enter to continue"

    # Tenant-specific app name - a generic shared name risks colliding both in
    # Entra (harder to tell tenants' app registrations apart) and locally (any
    # cert/file artifact written to the current folder using the app name as
    # its filename would overwrite another client's file of the same name).
    $tenantSlug = ($Tenant -split '\.')[0]
    $appName = "SPO-Archive-Automation-$tenantSlug"

    # Capture BOTH the returned object AND everything Register-PnPEntraIDApp
    # writes to the host (Write-Host output normally can't be captured, but
    # redirecting stream 6 - Information/Host - into the output pipeline
    # lets us regex it). This has proven more reliable than the cmdlet's own
    # return object, which has come back empty in testing.
    $capturedLines = @()
    $result = $null
    try {
        $capturedLines = Register-PnPEntraIDApp -ApplicationName $appName -Tenant $Tenant -Store CurrentUser `
            -SharePointApplicationPermissions "Sites.FullControl.All" 6>&1
        # Everything from the redirected host stream comes through as
        # InformationRecord objects - exclude those to isolate any genuine
        # pipeline return value, whatever its actual type turns out to be.
        $result = $capturedLines | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] } | Select-Object -Last 1
    } catch {
        $errMsg = $_.Exception.Message
        if ($errMsg -match 'already exist') {
            Write-Host "'$appName' already exists in Entra - generating a fresh certificate and attaching it to that existing app via Microsoft Graph, instead of registering a duplicate or asking for a manual portal upload." -ForegroundColor Yellow
            try {
                $newCert = New-SelfSignedCertificate -Subject "CN=$appName" -CertStoreLocation "Cert:\CurrentUser\My" `
                    -KeyExportPolicy Exportable -KeySpec Signature -KeyLength 2048 -NotAfter (Get-Date).AddYears(2) -ErrorAction Stop
                $existingApp = Get-ExistingAppClientId -AppName $appName -Tenant $Tenant
                if ($existingApp -and (Add-CertificateToEntraApp -App $existingApp -Thumbprint $newCert.Thumbprint)) {
                    $result = [PSCustomObject]@{ ClientId = $existingApp.AppId; Thumbprint = $newCert.Thumbprint }
                } else {
                    Write-Host "Automatic recovery failed - go delete '$appName' in the Entra portal (App registrations) first, then rerun this." -ForegroundColor Red
                }
            } catch {
                Write-Host "Automatic recovery failed: $($_.Exception.Message)" -ForegroundColor Red
            }
        } else {
            Write-Host "Register-PnPEntraIDApp reported: $errMsg" -ForegroundColor Red
        }
    }

    # ClientId: try the returned object first, then regex the captured host
    # text for "with id <guid>" (what Register-PnPEntraIDApp prints on success).
    $clientId = $result.ClientId
    if (-not $clientId) {
        $joined = ($capturedLines | Out-String)
        if ($joined -match 'with id ([0-9a-fA-F-]{36})') { $clientId = $Matches[1] }
    }

    # Thumbprint: try the returned object first, then fall back to the newest
    # certificate in the store whose subject matches this app name (reliable
    # now that -Store CurrentUser forces it to actually land there).
    $thumbprint = $result.Thumbprint
    if (-not $thumbprint) {
        $newestMatch = Get-ChildItem Cert:\CurrentUser\My -ErrorAction SilentlyContinue |
            Where-Object { $_.Subject -eq "CN=$appName" } |
            Sort-Object NotBefore -Descending | Select-Object -First 1
        if ($newestMatch) { $thumbprint = $newestMatch.Thumbprint }
    }

    Write-Host "`nClientId  : $(if ($clientId) { $clientId } else { '(not auto-detected)' })" -ForegroundColor Green
    Write-Host "Thumbprint: $(if ($thumbprint) { $thumbprint } else { '(not auto-detected)' })" -ForegroundColor Green
    Write-Host "(If either looks blank or wrong, you can overwrite it now.)" -ForegroundColor Yellow
    $clientId = Read-WithDefault "ClientId" $clientId
    $thumbprint = Read-WithDefault "Thumbprint" $thumbprint

    Write-Host "`nIMPORTANT: grant admin consent now - Entra portal > App registrations > $appName > API permissions > Grant admin consent." -ForegroundColor Cyan
    Write-Host "(A 401 error on first use right after this is usually just propagation delay, 5-30 min - not broken.)" -ForegroundColor Yellow
    Read-Host "Press Enter once you've granted consent (or to continue anyway)"

    Add-AppRegistryEntry -Tenant $Tenant -AppName $appName -ClientId $clientId -Thumbprint $thumbprint

    # Name the exported .pfx after THIS profile (matches the JSON filename)
    # and always write it into the same folder as the JSON files, so the two
    # are easy to pair up visually and easy to find on any machine.
    $exportPath = Join-Path $FolderPath "$ProfileBaseName-cert.pfx"
    if (-not (Test-Path $exportPath)) {
        $doExport = Read-Host "Export this certificate to '$ProfileBaseName-cert.pfx' (same folder as the JSON profiles) so it can be reused on another machine? (Y/N)"
        if ($doExport -match '^[Yy]') {
            $pwd = Read-Host "Set a password to protect the exported .pfx" -AsSecureString
            try {
                Export-PfxCertificate -Cert "Cert:\CurrentUser\My\$thumbprint" -FilePath $exportPath -Password $pwd | Out-Null
                Write-Host "Exported to $exportPath - remember the password, you'll need it to import elsewhere." -ForegroundColor Green
            } catch {
                Write-Host "Export failed: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    }

    return [PSCustomObject]@{ ClientId = $clientId; Thumbprint = $thumbprint }
}

function New-ProfileFromPrompts {
    param([string]$ProfileBaseName, [hashtable]$Existing = $null)

    $cfg = [ordered]@{}
    $cfg.Tenant = Read-WithDefault "Client tenant (e.g. clientname.onmicrosoft.com)" $Existing.Tenant
    $tenantPrefix = $cfg.Tenant.Split('.')[0]
    $cfg.TenantAdminUrl = Read-WithDefault "Tenant admin URL" ($Existing.TenantAdminUrl ?? "https://$tenantPrefix-admin.sharepoint.com")
    $cfg.SourceSiteUrl = Read-WithDefault "Source site URL" $Existing.SourceSiteUrl
    $cfg.SourceLibrary = Read-WithDefault "Source library" ($Existing.SourceLibrary ?? "Documents")
    $cfg.ArchiveSiteUrl = Read-WithDefault "Archive site URL" $Existing.ArchiveSiteUrl
    $cfg.ArchiveSiteTitle = Read-WithDefault "Archive site title" $Existing.ArchiveSiteTitle
    $cfg.SiteOwner = Read-WithDefault "Site owner UPN (needed to create the archive site under app-only auth)" $Existing.SiteOwner
    $cfg.ArchiveLibrary = Read-WithDefault "Archive library" ($Existing.ArchiveLibrary ?? "Documents")
    $cfg.ArchiveThresholdYears = [int](Read-WithDefault "Archive threshold (years)" ([string]($Existing.ArchiveThresholdYears ?? 5)))
    $cfg.TestFileLimit = [int](Read-WithDefault "Test file limit (0 = full run)" ([string]($Existing.TestFileLimit ?? 100)))
    $cfg.DryRun = (Read-WithDefault "Dry run? (true/false)" ([string]($Existing.DryRun ?? $true))) -match '^(?i)true$'

    $defaultLogName = ($cfg.SourceSiteUrl.TrimEnd('/') -split '/')[-1]
    if (-not $defaultLogName) { $defaultLogName = "client" }
    $cfg.LogPath = Read-WithDefault "Log file path" ($Existing.LogPath ?? "./archive-log-$defaultLogName.csv")

    $needsCreds = $true
    if ($Existing.ClientId -and $Existing.Thumbprint -and $Existing.Tenant -eq $cfg.Tenant) {
        $certOnDisk = Get-ChildItem "Cert:\CurrentUser\My\$($Existing.Thumbprint)" -ErrorAction SilentlyContinue
        if ($certOnDisk) {
            $cfg.ClientId = $Existing.ClientId
            $cfg.Thumbprint = $Existing.Thumbprint
            $needsCreds = $false
        }
    }
    if ($needsCreds) {
        $creds = Get-ClientAppCredentials -Tenant $cfg.Tenant -FolderPath $folder -ProfileBaseName $ProfileBaseName
        $cfg.ClientId = $creds.ClientId
        $cfg.Thumbprint = $creds.Thumbprint
    }

    return $cfg
}

function Save-Profile {
    param($Cfg, [string]$Path)
    ($Cfg | ConvertTo-Json -Depth 5) | Set-Content -Path $Path -Encoding UTF8
    Write-Host "Saved: $Path" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# [L] List every certificate this tool knows about, cross-referenced against
# the registry (for Tenant/AppName/ClientId) and current profiles (for
# "in use" status).
# ---------------------------------------------------------------------------
function Show-CertificateInventory {
    $registry = Get-AppRegistry
    $localCerts = Get-ChildItem Cert:\CurrentUser\My -ErrorAction SilentlyContinue |
        Where-Object { $_.Subject -like "CN=SPO-Archive-Automation*" }

    if (-not $localCerts) {
        Write-Host "No SPO-Archive-Automation certificates found on this machine." -ForegroundColor Yellow
        return
    }

    Write-Host "`n=== Certificates on this machine ===" -ForegroundColor Cyan
    $rows = foreach ($cert in $localCerts) {
        $reg = $registry | Where-Object { $_.Thumbprint -eq $cert.Thumbprint } | Select-Object -First 1
        $usedBy = @(Get-ProfilesUsingThumbprint -Thumbprint $cert.Thumbprint)
        [PSCustomObject]@{
            Subject    = $cert.Subject -replace '^CN=', ''
            Thumbprint = $cert.Thumbprint
            Created    = $cert.NotBefore.ToString("yyyy-MM-dd")
            Tenant     = if ($reg) { $reg.Tenant } else { "(unknown)" }
            UsedBy     = if ($usedBy.Count -gt 0) { $usedBy -join ", " } else { "(none - unused)" }
        }
    }
    $rows | Format-Table -AutoSize | Out-String | Write-Host
}

# ---------------------------------------------------------------------------
# [D] Delete certificates/registry entries no longer needed. Refuses to
# delete anything a saved profile still references unless explicitly forced.
# ---------------------------------------------------------------------------
function Remove-UnusedCertificates {
    $registry = Get-AppRegistry
    $localCerts = Get-ChildItem Cert:\CurrentUser\My -ErrorAction SilentlyContinue |
        Where-Object { $_.Subject -like "CN=SPO-Archive-Automation*" }

    if (-not $localCerts) {
        Write-Host "No SPO-Archive-Automation certificates found on this machine." -ForegroundColor Yellow
        return
    }

    # A cert created moments ago in THIS session may not be saved into any
    # profile yet - "unused" by profile-reference alone can't tell that apart
    # from a genuinely dead cert. Treat anything under 30 minutes old as
    # needing explicit confirmation even under [A] All, rather than silently
    # auto-deleting it (this is exactly what deleted velocityairau's cert
    # before its profile had been saved).
    $items = for ($i = 0; $i -lt $localCerts.Count; $i++) {
        $cert = $localCerts[$i]
        $usedBy = @(Get-ProfilesUsingThumbprint -Thumbprint $cert.Thumbprint)
        $recentlyCreated = ((Get-Date) - $cert.NotBefore).TotalMinutes -lt 30
        [PSCustomObject]@{ Index = $i + 1; Cert = $cert; UsedBy = $usedBy; RecentlyCreated = $recentlyCreated }
    }

    Write-Host "`n=== Certificates available to delete ===" -ForegroundColor Cyan
    foreach ($item in $items) {
        $tag = if ($item.UsedBy.Count -gt 0) { "IN USE by: $($item.UsedBy -join ', ')" }
               elseif ($item.RecentlyCreated) { "unused - but created <30 min ago, may not be saved to a profile yet" }
               else { "unused" }
        Write-Host "  [$($item.Index)] $($item.Cert.Subject -replace '^CN=','')  $($item.Cert.Thumbprint)  ($tag)"
    }
    Write-Host "  [A] All unused certificates"
    Write-Host "  [C] Cancel"
    $pick = Read-Host "`nSelect a number, A, or C"

    if ($pick -match '^[Cc]$') { return }

    $toDelete = @()
    if ($pick -match '^[Aa]$') {
        $safeToAutoDelete = $items | Where-Object { $_.UsedBy.Count -eq 0 -and -not $_.RecentlyCreated }
        $skippedRecent = @($items | Where-Object { $_.UsedBy.Count -eq 0 -and $_.RecentlyCreated })
        if ($skippedRecent.Count -gt 0) {
            Write-Host "Skipping $($skippedRecent.Count) cert(s) created in the last 30 minutes with no profile reference yet - they may belong to a registration you just did this session. Select individually if you're sure." -ForegroundColor Yellow
        }
        $toDelete = $safeToAutoDelete | ForEach-Object { $_.Cert }
        if (-not $toDelete) { Write-Host "Nothing safe to auto-delete." -ForegroundColor Yellow; return }
    } elseif ($pick -match '^\d+$' -and [int]$pick -ge 1 -and [int]$pick -le $items.Count) {
        $chosen = $items[[int]$pick - 1]
        if ($chosen.UsedBy.Count -gt 0) {
            $confirm = Read-Host "'$($chosen.Cert.Subject -replace '^CN=','')' is still used by $($chosen.UsedBy -join ', ') - delete anyway? Those profiles will stop working until re-pointed. (Y/N)"
            if ($confirm -notmatch '^[Yy]') { Write-Host "Cancelled." -ForegroundColor Yellow; return }
        } elseif ($chosen.RecentlyCreated) {
            $confirm = Read-Host "'$($chosen.Cert.Subject -replace '^CN=','')' was created in the last 30 minutes and isn't saved to any profile yet - it may belong to a registration you just did. Delete anyway? (Y/N)"
            if ($confirm -notmatch '^[Yy]') { Write-Host "Cancelled." -ForegroundColor Yellow; return }
        }
        $toDelete = @($chosen.Cert)
    } else {
        Write-Host "Invalid choice." -ForegroundColor Red
        return
    }

    foreach ($cert in $toDelete) {
        try {
            Remove-Item -Path "Cert:\CurrentUser\My\$($cert.Thumbprint)" -Force
            Write-Host "Deleted certificate: $($cert.Subject -replace '^CN=','') ($($cert.Thumbprint))" -ForegroundColor Green
        } catch {
            Write-Host "Failed to delete $($cert.Thumbprint): $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    $deletedThumbprints = $toDelete.Thumbprint
    $registry = @(Get-AppRegistry | Where-Object { $_.Thumbprint -notin $deletedThumbprints })
    Save-AppRegistry -Entries $registry
    Write-Host "Registry updated." -ForegroundColor Green
}

function Show-ActionMenu {
    param([string]$ProfilePath)

    while ($true) {
        $cfg = Get-Content $ProfilePath -Raw | ConvertFrom-Json -AsHashtable
        Write-Host "`n--- $(Split-Path $ProfilePath -Leaf) ---  (DryRun=$($cfg.DryRun)  TestFileLimit=$($cfg.TestFileLimit))" -ForegroundColor Cyan
        Write-Host "  [1] Run site-copy archive (uses settings above)"
        Write-Host "  [2] Toggle DryRun"
        Write-Host "  [3] Set TestFileLimit"
        Write-Host "  [4] Reconciliation check (read-only)"
        Write-Host "  [5] Rename problem files - preview"
        Write-Host "  [6] Rename problem files - execute"
        Write-Host "  [7] Cold storage archive - WhatIf"
        Write-Host "  [8] Cold storage archive - live"
        Write-Host "  [9] Export certificate (.pfx) for this profile"
        Write-Host "  [B] Back to profile list"
        Write-Host "  [Q] Quit"
        $action = Read-Host "Select an action"

        switch -Regex ($action) {
            '^1$' { & (Join-Path $folder "Archive-SharePointFiles.ps1") -ConfigPath $ProfilePath }
            '^2$' {
                $cfg.DryRun = -not $cfg.DryRun
                Save-Profile -Cfg $cfg -Path $ProfilePath
            }
            '^3$' {
                $cfg.TestFileLimit = [int](Read-WithDefault "New TestFileLimit (0 = full run)" ([string]$cfg.TestFileLimit))
                Save-Profile -Cfg $cfg -Path $ProfilePath
            }
            '^4$' { & (Join-Path $folder "Verify-ArchiveReconciliation.ps1") -ConfigPath $ProfilePath }
            '^5$' { & (Join-Path $folder "Rename-ProblemFiles.ps1") -ConfigPath $ProfilePath }
            '^6$' { & (Join-Path $folder "Rename-ProblemFiles.ps1") -ConfigPath $ProfilePath -Execute }
            '^7$' { & (Join-Path $folder "Archive-ToM365ColdStorage.ps1") -ConfigPath $ProfilePath -WhatIf }
            '^8$' { & (Join-Path $folder "Archive-ToM365ColdStorage.ps1") -ConfigPath $ProfilePath }
            '^9$' {
                if (-not $cfg.ClientId -or -not $cfg.Thumbprint) {
                    Write-Host "This profile has no ClientId/Thumbprint saved yet - nothing to export." -ForegroundColor Red
                } else {
                    $certOnDisk = Get-ChildItem "Cert:\CurrentUser\My\$($cfg.Thumbprint)" -ErrorAction SilentlyContinue
                    if (-not $certOnDisk) {
                        Write-Host "No certificate with thumbprint $($cfg.Thumbprint) is installed on this machine - nothing to export here." -ForegroundColor Red
                    } else {
                        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($ProfilePath)
                        $exportPath = Join-Path $folder "$baseName-cert.pfx"
                        if (Test-Path $exportPath) {
                            Write-Host "$exportPath already exists - delete it first if you want to re-export." -ForegroundColor Yellow
                        } else {
                            $pwd = Read-Host "Set a password to protect the exported .pfx" -AsSecureString
                            try {
                                Export-PfxCertificate -Cert "Cert:\CurrentUser\My\$($cfg.Thumbprint)" -FilePath $exportPath -Password $pwd | Out-Null
                                Write-Host "Exported to $exportPath" -ForegroundColor Green
                            } catch {
                                Write-Host "Export failed: $($_.Exception.Message)" -ForegroundColor Red
                            }
                        }
                    }
                }
            }
            '^[Bb]$' { return }
            '^[Qq]$' { exit }
            default { Write-Host "Invalid choice." -ForegroundColor Red }
        }
    }
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
Write-Host "=== SharePoint Archive - Client Profile Manager ===" -ForegroundColor Cyan

while ($true) {
    $profiles = Get-ChildItem -Path $folder -Filter "*.json" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch 'template' -and $_.Name -ne 'app-registry.json' }

    Write-Host "`nExisting profiles:" -ForegroundColor Yellow
    for ($i = 0; $i -lt $profiles.Count; $i++) {
        Write-Host "  [$($i + 1)] $($profiles[$i].Name)"
    }
    Write-Host "  [N] New client profile"
    Write-Host "  [L] List certificates on this machine"
    Write-Host "  [D] Delete unused certificates"
    Write-Host "  [Q] Quit"
    $choice = Read-Host "`nSelect a profile number, N, L, D, or Q"

    if ($choice -match '^[Qq]$') { break }
    if ($choice -match '^[Ll]$') { Show-CertificateInventory; continue }
    if ($choice -match '^[Dd]$') { Remove-UnusedCertificates; continue }

    if ($choice -match '^[Nn]$') {
        Write-Host "The name you give here is used for BOTH the JSON profile and its certificate file (e.g. 'Platinum - Creative')." -ForegroundColor Yellow
        $baseName = Read-Host "Profile name"
        $savePath = Join-Path $folder "$baseName.json"
        if (Test-Path $savePath) {
            Write-Host "'$baseName.json' already exists - pick this profile from the list instead, or choose a different name." -ForegroundColor Red
            continue
        }
        $cfg = New-ProfileFromPrompts -ProfileBaseName $baseName
        Save-Profile -Cfg $cfg -Path $savePath
        Show-ActionMenu -ProfilePath $savePath
        continue
    }

    if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $profiles.Count) {
        $activeProfile = $profiles[[int]$choice - 1].FullName
        $editChoice = Read-Host "Edit '$($profiles[[int]$choice - 1].Name)' before running? (Y/N)"
        if ($editChoice -match '^[Yy]') {
            $existing = Get-Content $activeProfile -Raw | ConvertFrom-Json -AsHashtable
            $baseName = [System.IO.Path]::GetFileNameWithoutExtension($activeProfile)
            $cfg = New-ProfileFromPrompts -ProfileBaseName $baseName -Existing $existing
            Save-Profile -Cfg $cfg -Path $activeProfile
        }
        Show-ActionMenu -ProfilePath $activeProfile
        continue
    }

    Write-Host "Invalid choice." -ForegroundColor Red
}

Write-Host "`nDone." -ForegroundColor Cyan
