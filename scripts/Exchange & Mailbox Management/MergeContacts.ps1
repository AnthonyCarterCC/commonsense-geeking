# ============================
#  MergeContacts.ps1
#  Interactive merge from CSV + email lookup
# ============================

param(
    [string]$CsvPath = "C:\Scripts\Xero_DuplicatePairs.csv"
)

# === VALIDATE CSV ===
if (-not (Test-Path $CsvPath)) {
    Write-Host "ERROR: CSV file not found at $CsvPath"
    exit
}

$Pairs = Import-Csv $CsvPath

if ($Pairs.Count -eq 0) {
    Write-Host "No duplicate pairs found in CSV."
    exit
}

# === TOKEN FILES ===
$TokenFile  = "C:\Scripts\LatestRefreshToken.txt"
$BackupFile = "C:\Scripts\LatestRefreshToken_backup.txt"

function Refresh-XeroToken {
    if (-not (Test-Path $TokenFile)) {
        Write-Host "ERROR: Token file missing."
        exit
    }

    $OldToken = (Get-Content -Raw $TokenFile).Trim()

    if ([string]::IsNullOrWhiteSpace($OldToken)) {
        Write-Host "ERROR: Token file is empty."
        exit
    }

    # Backup
    Set-Content -Path $BackupFile -Value $OldToken -Encoding ASCII

    $ClientID     = "4307454F378E44DFAFD1B333C556419C"
    $ClientSecret = "C6cpPlG1zGho-FhlkSjzuwqGijvAYNJgo_x7cRpPd4p0pYlq"

    $Body = @{
        grant_type    = "refresh_token"
        refresh_token = $OldToken
        client_id     = $ClientID
        client_secret = $ClientSecret
    }

    try {
        $response = Invoke-RestMethod -Method Post `
            -Uri "https://identity.xero.com/connect/token" `
            -Body $Body
    }
    catch {
        Write-Host "ERROR: Token refresh failed. Backup preserved."
        exit
    }

    $NewRefreshToken = $response.refresh_token
    $AccessToken     = $response.access_token

    if ([string]::IsNullOrWhiteSpace($NewRefreshToken)) {
        Write-Host "ERROR: No new refresh token returned. Backup preserved."
        exit
    }

    Set-Content -Path $TokenFile -Value $NewRefreshToken -Encoding ASCII

    return $AccessToken
}

function Get-XeroHeaders {
    param($AccessToken)

    $Headers = @{
        Authorization = "Bearer $AccessToken"
        Accept        = "application/json"
        "Content-Type" = "application/json"
    }

    $Tenants = Invoke-RestMethod -Method GET `
        -Uri "https://api.xero.com/connections" `
        -Headers $Headers

    $TenantID = $Tenants[0].tenantId
    $Headers["Xero-tenant-id"] = $TenantID

    return $Headers
}

function Get-XeroContact {
    param(
        [string]$ContactID,
        $Headers
    )

    $url = "https://api.xero.com/api.xro/2.0/Contacts/$ContactID"
    $result = Invoke-RestMethod -Method GET -Uri $url -Headers $Headers
    return $result.Contacts[0]
}

function Merge-XeroContacts {
    param(
        [string]$MasterID,
        [string]$DuplicateID,
        $Headers
    )

    $Body = @{
        ContactID = $MasterID
    } | ConvertTo-Json

    try {
        Invoke-RestMethod -Method POST `
            -Uri "https://api.xero.com/api.xro/2.0/Contacts/$DuplicateID/Merge" `
            -Headers $Headers `
            -Body $Body

        Write-Host "Merged $DuplicateID → $MasterID"
    }
    catch {
        Write-Host "ERROR: Merge failed for $DuplicateID → $MasterID"
        Write-Host $_.Exception.Message
    }
}

# === MAIN LOOP ===

foreach ($pair in $Pairs) {

    # Refresh token + headers for each pair
    $AccessToken = Refresh-XeroToken
    $Headers = Get-XeroHeaders -AccessToken $AccessToken

    # Fetch full contact details
    $A = Get-XeroContact -ContactID $pair.A_ID -Headers $Headers
    $B = Get-XeroContact -ContactID $pair.B_ID -Headers $Headers

    Write-Host ""
    Write-Host "====================================="
    Write-Host "Duplicate Pair:"
    Write-Host ""
    Write-Host "A: $($A.Name)"
    Write-Host "   Email: $($A.EmailAddress)"
    Write-Host ""
    Write-Host "B: $($B.Name)"
    Write-Host "   Email: $($B.EmailAddress)"
    Write-Host ""
    Write-Host "====================================="
    Write-Host "Choose:"
    Write-Host "  A = merge B → A"
    Write-Host "  B = merge A → B"
    Write-Host "  S = skip"
    Write-Host "  Q = quit"
    Write-Host ""

    $choice = Read-Host "Your choice"

    switch ($choice.ToUpper()) {

        "A" {
            Merge-XeroContacts -MasterID $pair.A_ID -DuplicateID $pair.B_ID -Headers $Headers
        }

        "B" {
            Merge-XeroContacts -MasterID $pair.B_ID -DuplicateID $pair.A_ID -Headers $Headers
        }

        "S" {
            Write-Host "Skipped."
        }

        "Q" {
            Write-Host "Quitting."
            exit
        }

        default {
            Write-Host "Invalid choice. Skipped."
        }
    }
}

Write-Host "All pairs processed."
