# ============================
#  DuplicateFinder.ps1
#  Active customers only + clean-name matching + unique pairs only
# ============================

$CsvOut = "C:\Scripts\Xero_DuplicatePairs.csv"
$TokenFile  = "C:\Scripts\LatestRefreshToken.txt"
$BackupFile = "C:\Scripts\LatestRefreshToken_backup.txt"

# === VALIDATE TOKEN FILE ===
if (-not (Test-Path $TokenFile)) {
    Write-Host "ERROR: Token file missing."
    exit
}

$RefreshToken = (Get-Content -Raw $TokenFile).Trim()

if ([string]::IsNullOrWhiteSpace($RefreshToken)) {
    Write-Host "ERROR: Refresh token file is EMPTY."
    exit
}

# === BACKUP TOKEN ===
Set-Content -Path $BackupFile -Value $RefreshToken -Encoding ASCII
Write-Host "Backup created."

$ClientID     = "4307454F378E44DFAFD1B333C556419C"
$ClientSecret = "C6cpPlG1zGho-FhlkSjzuwqGijvAYNJgo_x7cRpPd4p0pYlq"

Write-Host "Refreshing token..."

$Body = @{
    grant_type    = "refresh_token"
    refresh_token = $RefreshToken
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

$AccessToken     = $response.access_token
$NewRefreshToken = $response.refresh_token

if ([string]::IsNullOrWhiteSpace($NewRefreshToken)) {
    Write-Host "ERROR: No new refresh token returned. Backup preserved."
    exit
}

Set-Content -Path $TokenFile -Value $NewRefreshToken -Encoding ASCII
Write-Host "Token refreshed."

# === BUILD HEADERS ===
$Headers = @{
    Authorization = "Bearer $AccessToken"
    Accept        = "application/json"
}

# === GET TENANT ===
$Tenants = Invoke-RestMethod -Method GET `
    -Uri "https://api.xero.com/connections" `
    -Headers $Headers

$TenantID = $Tenants[0].tenantId
$Headers["Xero-tenant-id"] = $TenantID

# === GET ACTIVE CONTACTS ===
Write-Host "Downloading active contacts..."
$Contacts = Invoke-RestMethod -Method GET `
    -Uri "https://api.xero.com/api.xro/2.0/Contacts?includeArchived=false" `
    -Headers $Headers

$CustomerContacts = $Contacts.Contacts | Where-Object { $_.IsCustomer -eq $true }

Write-Host "Loaded $($CustomerContacts.Count) active customers."

# === NORMALISE NAME (SAFE) ===
function Normalize-Name {
    param($name)

    if ([string]::IsNullOrWhiteSpace($name)) { return "" }

    return $name.ToLower().
        Replace("pty ltd","").
        Replace("pty","").
        Replace("ltd","").
        Replace("&","and").
        Replace(".","").
        Replace(",","").
        Trim()
}

# === BUILD CLEANED LIST ===
$Cleaned = @()

foreach ($c in $CustomerContacts) {

    $clean = Normalize-Name $c.Name

    if ($clean -eq "") { continue }

    $Cleaned += [PSCustomObject]@{
        CleanName = $clean
        Original  = $c
    }
}

# === GROUP BY CLEANED NAME ROOT ===
$Groups = $Cleaned | Group-Object CleanName

$PossibleDuplicates = @()

foreach ($g in $Groups) {
    if ($g.Count -gt 1) {

        # UNIQUE PAIRS ONLY
        for ($i = 0; $i -lt $g.Group.Count; $i++) {
            for ($j = $i + 1; $j -lt $g.Group.Count; $j++) {

                $a = $g.Group[$i]
                $b = $g.Group[$j]

                $PossibleDuplicates += [PSCustomObject]@{
                    A     = $a.Original.Name
                    B     = $b.Original.Name
                    A_ID  = $a.Original.ContactID
                    B_ID  = $b.Original.ContactID
                }
            }
        }
    }
}

# === WRITE CSV OUTPUT ===
if ($PossibleDuplicates.Count -gt 0) {
    $PossibleDuplicates |
        Sort-Object A,B |
        Export-Csv -Path $CsvOut -NoTypeInformation -Encoding UTF8

    Write-Host "CSV created: $CsvOut"
} else {
    Write-Host "No duplicates found."
}

Write-Host "`nDone."
