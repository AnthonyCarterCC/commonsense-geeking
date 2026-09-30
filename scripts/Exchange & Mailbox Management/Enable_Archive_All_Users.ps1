# Enable Online Archive for Mailboxes >= 20GB
# Run this after connecting with Connect-ExchangeOnline -DelegatedOrganization

# ===== CHECK: View mailboxes >= 20GB WITHOUT archive enabled =====
Get-Mailbox -ResultSize Unlimited | Where-Object {$_.ArchiveStatus -eq "None" -and $_.RecipientTypeDetails -ne "SharedMailbox"} | ForEach-Object {
    $stats = Get-MailboxStatistics -Identity $_.PrimarySmtpAddress
    $text = $stats.TotalItemSize
    if ($text -match '(\d+\.?\d*)\s*(KB|MB|GB)') {
        $size = [double]$matches[1]
        $unit = $matches[2]
        $sizeGB = switch ($unit) {
            'KB' { [math]::Round($size / 1024 / 1024, 2) }
            'MB' { [math]::Round($size / 1024, 2) }
            'GB' { $size }
        }
        if ($sizeGB -ge 20) {
            $_ | Select-Object DisplayName, PrimarySmtpAddress, ArchiveStatus, @{Name="SizeGB";Expression={$sizeGB}}
        }
    }
} | Format-Table -AutoSize

# ===== ENABLE: Archive for mailboxes >= 20GB (excluding shared) =====
Get-Mailbox -ResultSize Unlimited | Where-Object {$_.ArchiveStatus -eq "None" -and $_.RecipientTypeDetails -ne "SharedMailbox"} | ForEach-Object {
    $stats = Get-MailboxStatistics -Identity $_.PrimarySmtpAddress
    $text = $stats.TotalItemSize
    if ($text -match '(\d+\.?\d*)\s*(KB|MB|GB)') {
        $size = [double]$matches[1]
        $unit = $matches[2]
        $sizeGB = switch ($unit) {
            'KB' { [math]::Round($size / 1024 / 1024, 2) }
            'MB' { [math]::Round($size / 1024, 2) }
            'GB' { $size }
        }
        if ($sizeGB -ge 20) {
            Enable-Mailbox -Identity $_.PrimarySmtpAddress -Archive
            Write-Host "Enabled archive for $($_.DisplayName) - Size: $sizeGB GB"
        }
    }
}

# ===== VERIFY: Confirm archives are now enabled =====
Get-Mailbox -ResultSize Unlimited | Where-Object {$_.ArchiveStatus -eq "Active" -and $_.RecipientTypeDetails -ne "SharedMailbox"} | ForEach-Object {
    $stats = Get-MailboxStatistics -Identity $_.PrimarySmtpAddress
    $text = $stats.TotalItemSize
    if ($text -match '(\d+\.?\d*)\s*(KB|MB|GB)') {
        $size = [double]$matches[1]
        $unit = $matches[2]
        $sizeGB = switch ($unit) {
            'KB' { [math]::Round($size / 1024 / 1024, 2) }
            'MB' { [math]::Round($size / 1024, 2) }
            'GB' { $size }
        }
        if ($sizeGB -ge 20) {
            $_ | Select-Object DisplayName, PrimarySmtpAddress, ArchiveStatus, @{Name="SizeGB";Expression={$sizeGB}}
        }
    }
} | Format-Table -AutoSize
