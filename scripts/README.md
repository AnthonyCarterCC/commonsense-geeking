# Commonsense Scripts Repository

A centralized collection of PowerShell and Python scripts for system administration, security management, and IT operations.

## Categories

### Azure Security
- **Audit-EntraSecurity.ps1** - Read-only audit of Entra ID security posture for brute-force and legacy-auth attack prevention.
- **Remediate-EntraSecurity.ps1** - Remediates Entra ID security findings from the audit script.

### BloatWare
- **Cleanup-WindowsUpdates.ps1** - Removes unnecessary and old Windows Update files to free up disk space.
- **Disable-BrowserNotifications.ps1** - Disables intrusive browser notifications in Windows.
- **Remove-DellBloatware.ps1** - Removes Dell pre-installed apps and utilities on Dell systems.
- **Remove-LenovoBloatware.ps1** - Removes Lenovo pre-installed apps and utilities on Lenovo systems.
- **Remove-Windows10Bloatware.ps1** - Removes built-in Windows 10 bloatware and unnecessary apps.
- **Windows11_Cleanup.ps1** - Comprehensive Windows 11 cleanup and optimization script.

### Deployment & Build
- **CorporateBuild.ps1** - Comprehensive corporate machine build and provisioning script for enterprise deployments.

### Exchange & Mailbox Management
- **Add_Archive_Prefix_SharedMailboxes.ps1** - Adds archive prefix to shared mailbox names for organization.
- **Convert_SharedMailboxes_CloudManaged.ps1** - Converts shared mailboxes to cloud-managed configurations.
- **Enable_Archive_All_Users.ps1** - Enables mailbox archiving for all users in the organization.
- **Enable-DKIM-O365.ps1** - Enables DKIM signing for Office 365 domain authentication.
- **ExchangeOnline_DelegatedAccess_Setup.ps1** - Sets up delegated access permissions in Exchange Online.
- **Hide_CloudOnly_SharedMailboxes_GAL.ps1** - Hides cloud-only shared mailboxes from the Global Address List.
- **Hide_Shared_Mailboxes_GAL.ps1** - Hides shared mailboxes from the Global Address List.
- **Initialize-ArchiverEnvironment.ps1** - Initializes the mail archiving environment and prerequisites.
- **Mailboxes_Over50GB_With_ArchiveSize.ps1** - Reports on mailboxes over 50GB with archive sizes.
- **Manage-M365GroupOwners.ps1** - Manages Microsoft 365 group ownership and permissions.
- **MergeContacts.ps1** - Merges duplicate contacts in Exchange mailboxes.
- **Run-QuarterlyArchive.ps1** - Executes quarterly mailbox archiving operations.

### Local Admin
- **Promote-CurrentUserToLocalAdmin.ps1** - Promotes the current user to local administrator without password.

### Security & Defender
- **Configure-DefenderQuiet.ps1** - Configures Windows Defender for quiet operation without notifications.
- **Defender365Fix.ps1** - Fixes Windows Defender integration issues with Microsoft 365.
- **Verify-Harmoniq-gMSA.ps1** - Verifies Harmoniq group Managed Service Account status.

### SharePoint & OneDrive
- **Archive-StaleSharePointFiles.ps1** - Archives old and stale files from SharePoint sites.
- **Clear-OneDriveCrash.ps1** - Clears OneDrive sync errors and crash logs.
- **Get-AllClientSharePointSites.ps1** - Enumerates all SharePoint sites accessible to the client.
- **Get-OneDriveSyncStatus.ps1** - Reports OneDrive synchronization status and issues.
- **Remove-OneDriveApps.ps1** - Removes OneDrive application and cleans up residual files.

#### Archive (Arc) Subdirectory
- **Archive-SharePointFiles.ps1** - Archives SharePoint files to cold storage.
- **Archive-ToM365ColdStorage.ps1** - Migrates files to Microsoft 365 cold storage.
- **Manage-ArchiveProfiles.ps1** - Manages archive profiles and configurations.
- **Remove-EmptyFolders.ps1** - Removes empty folders after archival operations.
- **Rename-ProblemFiles.ps1** - Renames files with special characters or naming issues.
- **Verify-ArchiveReconciliation.ps1** - Verifies archive operations completed correctly.

### System Troubleshooting
- **Fix-ModulePaths.ps1** - Fixes PowerShell module path issues and configurations.
- **Fix-SpellCheck-Win10.ps1** - Repairs Windows 10 spell check functionality.
- **Fix-SpellCheck.ps1** - General spell check repair for Windows systems.
- **Reset-Teams.ps1** - Resets Microsoft Teams client cache and configuration.
- **ResetCreds.ps1** - Resets cached credentials and clears credential vault.

### Utilities
- **DuplicateFinder.ps1** - Finds and reports duplicate files based on content hashing.
- **youtube_transcript_downloader.py** - Python script to download YouTube video transcripts.

---
**Repository:** commonsense-scripts (GitHub)
