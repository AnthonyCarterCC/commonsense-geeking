# Convert Synced Shared Mailboxes to Cloud-Managed Exchange Attributes
# This removes Exchange attribute sync from on-premises, making them cloud-managed
# Run this after connecting with Connect-ExchangeOnline -DelegatedOrganization

# ===== CHECK: View synced shared mailboxes =====
Get-Mailbox -RecipientTypeDetails SharedMailbox -ResultSize Unlimited | Where-Object {$_.IsDirSynced -eq $true} | Select-Object DisplayName, IsDirSynced, IsExchangeCloudManaged

# ===== CONVERT: Make all synced shared mailboxes cloud-managed =====
Get-Mailbox -RecipientTypeDetails SharedMailbox -ResultSize Unlimited | Where-Object {$_.IsDirSynced -eq $true} | ForEach-Object {
    Set-Mailbox -Identity $_.Identity -IsExchangeCloudManaged $true
    Write-Host "Converted to cloud-managed: $($_.DisplayName)"
}

# ===== VERIFY: Confirm all synced shared mailboxes are now cloud-managed =====
Get-Mailbox -RecipientTypeDetails SharedMailbox -ResultSize Unlimited | Where-Object {$_.IsDirSynced -eq $true} | Select-Object DisplayName, IsDirSynced, IsExchangeCloudManaged

# ===== INFO: Cloud-managed means Exchange attributes are now editable in cloud =====
# The mailbox is still synced for identity, but Exchange properties are now managed here, not on-premises
