# Mailboxes over 50GB + Archive Mailbox Sizes
# Run this after connecting with Connect-ExchangeOnline -DelegatedOrganization

Get-Mailbox -ResultSize Unlimited | ForEach-Object {
    $primaryStats = Get-MailboxStatistics -Identity $_.PrimarySmtpAddress
    $primarySizeGB = if ($primaryStats.TotalItemSize -match '(\d+\.?\d*)\s*(KB|MB|GB)') {
        $size = [double]$matches[1]; $unit = $matches[2]
        switch ($unit) { 'KB' { [math]::Round($size/1024/1024,2) } 'MB' { [math]::Round($size/1024,2) } 'GB' { $size } }
    } else { 0 }

    $archiveSizeGB = "No Archive"
    if ($_.ArchiveStatus -eq "Active") {
        $archiveStats = Get-MailboxStatistics -Identity $_.PrimarySmtpAddress -Archive
        $archiveSizeGB = if ($archiveStats.TotalItemSize -match '(\d+\.?\d*)\s*(KB|MB|GB)') {
            $size = [double]$matches[1]; $unit = $matches[2]
            switch ($unit) { 'KB' { [math]::Round($size/1024/1024,2) } 'MB' { [math]::Round($size/1024,2) } 'GB' { $size } }
        } else { 0 }
    }

    if ($primarySizeGB -ge 50) {
        [PSCustomObject]@{
            DisplayName    = $_.DisplayName
            Email          = $_.PrimarySmtpAddress
            Type           = $_.RecipientTypeDetails
            MailboxGB      = $primarySizeGB
            ArchiveEnabled = $_.ArchiveStatus
            ArchiveGB      = $archiveSizeGB
        }
    }
} | Sort-Object MailboxGB -Descending | Format-Table -AutoSize

Get-Mailbox -ResultSize Unlimited | ForEach-Object {
    Start-ManagedFolderAssistant -Identity $_.PrimarySmtpAddress
    Write-Host "Started MFA for $($_.DisplayName)"
}


