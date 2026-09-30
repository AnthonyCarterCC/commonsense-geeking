<#
.SYNOPSIS
    Runs the archiver for one or more clients defined in a config file.
    Lets you maintain one config per tenant instead of retyping parameters each time.

.DESCRIPTION
    Reads Clients.json (see Clients.example.json for format), and for each enabled
    client entry, invokes Archive-StaleSharePointFiles.ps1 with that client's settings.

    Run dry-run across ALL clients first each quarter, review every CSV, THEN run live
    per client (or all at once if you're confident).

.EXAMPLE
    # Dry run for all enabled clients
    .\Run-QuarterlyArchive.ps1 -ConfigPath .\Clients.json

.EXAMPLE
    # Live run for a single named client only
    .\Run-QuarterlyArchive.ps1 -ConfigPath .\Clients.json -ClientName "Contoso" -LiveRun

.EXAMPLE
    # Live run for all enabled clients
    .\Run-QuarterlyArchive.ps1 -ConfigPath .\Clients.json -LiveRun
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath,

    [Parameter(Mandatory = $false)]
    [string]$ClientName,

    [Parameter(Mandatory = $false)]
    [switch]$LiveRun,

    [Parameter(Mandatory = $false)]
    [switch]$DeleteAfterCopy
)

if (-not (Test-Path $ConfigPath)) {
    throw "Config file not found: $ConfigPath"
}

$clients = Get-Content $ConfigPath -Raw | ConvertFrom-Json

foreach ($client in $clients) {

    if (-not $client.Enabled) {
        Write-Host "Skipping disabled client: $($client.Name)" -ForegroundColor DarkGray
        continue
    }
    if ($ClientName -and $client.Name -ne $ClientName) {
        continue
    }

    Write-Host ""
    Write-Host "================================================================" -ForegroundColor Cyan
    Write-Host " Running archiver for client: $($client.Name)" -ForegroundColor Cyan
    Write-Host "================================================================" -ForegroundColor Cyan

    $securePwd = if ($client.CertificatePassword) {
        ConvertTo-SecureString $client.CertificatePassword -AsPlainText -Force
    } else { $null }

    $params = @{
        SourceSiteUrl            = $client.SourceSiteUrl
        SourceLibrary            = $client.SourceLibrary
        DestinationSiteUrl       = $client.DestinationSiteUrl
        DestinationLibrary       = $client.DestinationLibrary
        MonthsInactiveThreshold  = $client.MonthsInactiveThreshold
        ClientId                 = $client.AppClientId
        Tenant                   = $client.TenantId
        CertificatePath          = $client.CertificatePath
        OutputDirectory          = Join-Path ".\Logs" $client.Name
    }
    if ($securePwd)            { $params["CertificatePassword"] = $securePwd }
    if ($client.ExcludeFolders) { $params["ExcludeFolders"] = $client.ExcludeFolders }
    if ($LiveRun)               { $params["LiveRun"] = $true }
    if ($DeleteAfterCopy)       { $params["DeleteAfterCopy"] = $true }

    try {
        & .\Archive-StaleSharePointFiles.ps1 @params
    }
    catch {
        Write-Host "Client '$($client.Name)' FAILED: $($_.Exception.Message)" -ForegroundColor Red
        # Continue to next client rather than aborting the whole batch
        continue
    }
}
