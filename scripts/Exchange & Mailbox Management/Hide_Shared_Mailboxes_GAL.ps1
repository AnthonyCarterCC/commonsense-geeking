# Hide All Shared Mailboxes from Global Address List (GAL)
# Run this after connecting with Connect-ExchangeOnline -DelegatedOrganization

# ===== CHECK: View shared mailboxes currently visible in GAL =====
Get-Mailbox -RecipientTypeDetails SharedMailbox -ResultSize Unlimited | Where-Object {$_.HiddenFromAddressListsEnabled -eq $false} | Select-Object DisplayName, PrimarySmtpAddress, HiddenFromAddressListsEnabled

# ===== HIDE: Remove all shared mailboxes from GAL =====
Get-Mailbox -RecipientTypeDetails SharedMailbox -ResultSize Unlimited | Set-Mailbox -HiddenFromAddressListsEnabled $true

# ===== VERIFY: Confirm all shared mailboxes are now hidden =====
Get-Mailbox -RecipientTypeDetails SharedMailbox -ResultSize Unlimited | Select-Object DisplayName, HiddenFromAddressListsEnabled

# ===== OPTIONAL: If you want to hide a SPECIFIC shared mailbox instead =====
# Set-Mailbox -Identity "SharedMailboxName" -HiddenFromAddressListsEnabled $true
