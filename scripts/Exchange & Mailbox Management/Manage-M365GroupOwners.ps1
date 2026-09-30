# Interactive Microsoft 365 Group Owner Manager
# Uses the existing Microsoft Graph PowerShell session and does not disconnect it.

$ErrorActionPreference = 'Stop'
$GraphBase = 'https://' + 'graph.microsoft.com/v1.0'

function Pause-Return {
    [void](Read-Host 'Press ENTER to return to PowerShell')
}

try {
    $context = Get-MgContext
    if (-not $context -or -not $context.Account) {
        throw 'No active Microsoft Graph session. Connect-MgGraph first.'
    }

    Write-Host "Using existing Graph login: $($context.Account)" -ForegroundColor Green
    $search = (Read-Host 'Enter group name or part of name, for example Coco').Trim()
    if ([string]::IsNullOrWhiteSpace($search)) { throw 'No group name entered.' }

    # Server-side search is avoided because the installed SDK group cmdlet is failing.
    $uri = $GraphBase + '/groups?$top=999&$select=id,displayName,mail'
    $result = Invoke-MgGraphRequest -Method GET -Uri $uri
    $groups = @($result['value'] | Where-Object { $_['displayName'] -like "*$search*" })

    if ($groups.Count -eq 0) { throw "No groups matched '$search'." }

    Write-Host ''
    Write-Host 'MATCHING GROUPS' -ForegroundColor Cyan
    for ($i = 0; $i -lt $groups.Count; $i++) {
        Write-Host ("[{0}] {1} - {2}" -f ($i + 1), $groups[$i]['displayName'], $groups[$i]['mail'])
    }

    do {
        $choice = Read-Host 'Select group number'
        $valid = ($choice -match '^\d+$') -and ([int]$choice -ge 1) -and ([int]$choice -le $groups.Count)
        if (-not $valid) { Write-Host 'Invalid selection.' -ForegroundColor Red }
    } until ($valid)

    $group = $groups[[int]$choice - 1]
    $groupId = $group['id']
    $groupName = $group['displayName']

    while ($true) {
        $ownersUri = $GraphBase + '/groups/' + $groupId + '/owners?$select=id,displayName,userPrincipalName'
        $ownersResult = Invoke-MgGraphRequest -Method GET -Uri $ownersUri
        $owners = @($ownersResult['value'])

        Write-Host ''
        Write-Host "GROUP: $groupName" -ForegroundColor Yellow
        Write-Host 'CURRENT OWNERS' -ForegroundColor Cyan
        if ($owners.Count -eq 0) {
            Write-Host 'No owners assigned.' -ForegroundColor Yellow
        } else {
            for ($i = 0; $i -lt $owners.Count; $i++) {
                $ownerName = $owners[$i]['displayName']
                $ownerUpn = $owners[$i]['userPrincipalName']
                if ([string]::IsNullOrWhiteSpace($ownerUpn)) { $ownerUpn = $owners[$i]['id'] }
                Write-Host ("[{0}] {1} - {2}" -f ($i + 1), $ownerName, $ownerUpn)
            }
        }

        Write-Host ''
        Write-Host '[A] Add owner'
        Write-Host '[R] Remove owner'
        Write-Host '[Q] Finish'
        $action = (Read-Host 'Choose action').Trim().ToUpperInvariant()

        switch ($action) {
            'A' {
                try {
                    $upn = (Read-Host "Enter new owner's email address").Trim()
                    if ([string]::IsNullOrWhiteSpace($upn)) { throw 'No email address entered.' }
                    $userUri = $GraphBase + '/users/' + [uri]::EscapeDataString($upn) + '?$select=id,displayName,userPrincipalName'
                    $user = Invoke-MgGraphRequest -Method GET -Uri $userUri
                    $body = @{ '@odata.id' = $GraphBase + '/directoryObjects/' + $user['id'] } | ConvertTo-Json -Compress
                    $addUri = $GraphBase + '/groups/' + $groupId + '/owners/$ref'
                    Invoke-MgGraphRequest -Method POST -Uri $addUri -Body $body -ContentType 'application/json' | Out-Null
                    Write-Host ("Owner added: {0}" -f $user['displayName']) -ForegroundColor Green
                } catch {
                    Write-Host ("ADD FAILED: {0}" -f $_.Exception.Message) -ForegroundColor Red
                }
            }
            'R' {
                if ($owners.Count -le 1) {
                    Write-Host 'The final owner cannot be removed.' -ForegroundColor Red
                    continue
                }
                $removeChoice = Read-Host 'Enter owner number to remove'
                $removeValid = ($removeChoice -match '^\d+$') -and ([int]$removeChoice -ge 1) -and ([int]$removeChoice -le $owners.Count)
                if (-not $removeValid) {
                    Write-Host 'Invalid owner number.' -ForegroundColor Red
                    continue
                }
                try {
                    $owner = $owners[[int]$removeChoice - 1]
                    $removeUri = $GraphBase + '/groups/' + $groupId + '/owners/' + $owner['id'] + '/$ref'
                    Invoke-MgGraphRequest -Method DELETE -Uri $removeUri | Out-Null
                    Write-Host ("Owner removed: {0}" -f $owner['displayName']) -ForegroundColor Green
                } catch {
                    Write-Host ("REMOVE FAILED: {0}" -f $_.Exception.Message) -ForegroundColor Red
                }
            }
            'Q' { break }
            default { Write-Host 'Invalid option.' -ForegroundColor Red }
        }

        if ($action -eq 'Q') { break }
    }
}
catch {
    Write-Host ("ERROR: {0}" -f $_.Exception.Message) -ForegroundColor Red
}

Write-Host ''
Write-Host 'Graph remains connected. This script does not disconnect your session.' -ForegroundColor Cyan
Pause-Return
