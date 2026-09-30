# Add "Archive-" Prefix to Shared Mailboxes
# Run this after connecting with Connect-ExchangeOnline -DelegatedOrganization

# ===== CHECK: View shared mailboxes WITHOUT "Archive-" prefix =====
Get-Mailbox -RecipientTypeDetails SharedMailbox -ResultSize Unlimited | Where-Object {$_.DisplayName -notlike "Archive-*"} | Select-Object DisplayName, IsDirSynced

# ===== RENAME: Cloud-only shared mailboxes (skip synced ones) =====
Get-Mailbox -RecipientTypeDetails SharedMailbox -ResultSize Unlimited | Where-Object {$_.DisplayName -notlike "Archive-*" -and $_.IsDirSynced -eq $false} | ForEach-Object {
    $newDisplayName = "Archive-" + $_.DisplayName
    Set-Mailbox -Identity $_.Identity -DisplayName $newDisplayName
    Write-Host "Renamed: $($_.DisplayName) -> $newDisplayName"
}

# ===== VERIFY: Check all shared mailboxes now have prefix =====
Get-Mailbox -RecipientTypeDetails SharedMailbox -ResultSize Unlimited | Select-Object DisplayName, IsDirSynced

# ===== NOTE: Synced mailboxes (IsDirSynced = True) need to be renamed on-premises in AD =====
# Example: Rename-ADObject -Identity "CN=Sharon Thomas,OU=Users,DC=yourdomain,DC=com" -NewName "Archive-Sharon Thomas"
