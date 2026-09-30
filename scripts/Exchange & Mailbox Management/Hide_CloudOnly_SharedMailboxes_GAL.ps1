# Hide CLOUD-ONLY Shared Mailboxes from GAL (skip on-premises synced ones)
# Run this after connecting with Connect-ExchangeOnline -DelegatedOrganization

# ===== CHECK: View cloud-only shared mailboxes currently visible in GAL =====
Get-Mailbox -RecipientTypeDetails SharedMailbox -ResultSize Unlimited | Where-Object {$_.IsDirSynced -eq $false -and $_.HiddenFromAddressListsEnabled -eq $false} | Select-Object DisplayName, PrimarySmtpAddress, IsDirSynced, HiddenFromAddressListsEnabled

# ===== LIST: Show synced mailboxes (these need to be done on-premises) =====
Get-Mailbox -RecipientTypeDetails SharedMailbox -ResultSize Unlimited | Where-Object {$_.IsDirSynced -eq $true} | Select-Object DisplayName, IsDirSynced

# ===== HIDE: Remove only cloud-only shared mailboxes from GAL =====
Get-Mailbox -RecipientTypeDetails SharedMailbox -ResultSize Unlimited | Where-Object {$_.IsDirSynced -eq $false} | Set-Mailbox -HiddenFromAddressListsEnabled $true

# ===== VERIFY: Confirm cloud-only shared mailboxes are now hidden =====
Get-Mailbox -RecipientTypeDetails SharedMailbox -ResultSize Unlimited | Select-Object DisplayName, IsDirSynced, HiddenFromAddressListsEnabled
