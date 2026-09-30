# SharePoint Archive Automation — New Client Setup Guide

Repeat this whole process per client (app-only cert auth is per-tenant, nothing carries over).

## 0. Info needed from you before starting

- Tenant name (`CLIENTTENANT.onmicrosoft.com`)
- Source site URL
- Source library name (confirm — usually "Documents" but internal name is often "Shared Documents")
- Archive site URL (script creates it if missing)
- Archive threshold in years
- Test file limit (or none for full run)

## 1. Install modules (one-time per machine, not per client)

In **PowerShell 7**:
```powershell
Install-Module -Name PnP.PowerShell -Scope CurrentUser -Force
```

In **Windows PowerShell 5.1** (separate window — SPO module is Desktop-only, PnP is Core-only, they can't share a session):
```powershell
Install-Module -Name Microsoft.Online.SharePoint.PowerShell -Scope CurrentUser -Force
```

## 2. Register the Entra app + certificate (PowerShell 7)

```powershell
Register-PnPEntraIDApp -ApplicationName "SPO-Archive-Automation" `
    -Tenant "CLIENTTENANT.onmicrosoft.com" `
    -SharePointApplicationPermissions "Sites.FullControl.All"
```

- Pops a browser — sign in as Global Admin for the client tenant.
- If it errors "application already exists," either reuse the existing registration (grab ClientId from Entra portal → App registrations) or pick a new `-ApplicationName`.
- Output gives you **ClientId** and **Thumbprint** — copy both into config.json.

## 3. Grant admin consent

Azure portal → Entra ID → App registrations → [app] → API permissions → confirm `Sites.FullControl.All` shows a green check. If not, click **Grant admin consent for [tenant]**.

**Known gotcha:** consent can take 5–30+ min to propagate to SharePoint's own permission cache. A 401 Unauthorized right after granting consent is usually just this — wait and retest before assuming something's broken.

## 4. Confirm DisableCustomAppAuthentication is off

In **Windows PowerShell 5.1**:
```powershell
Connect-SPOService -Url https://CLIENTTENANT-admin.sharepoint.com
Get-SPOTenant | Select-Object DisableCustomAppAuthentication
```
If `True`:
```powershell
Set-SPOTenant -DisableCustomAppAuthentication $false
```

## 5. Fill in config.json

Use `config.template.json` as the starting point. Fill in TenantAdminUrl, SourceSiteUrl, SourceLibrary, ArchiveSiteUrl, ArchiveSiteTitle, ArchiveLibrary, ArchiveThresholdYears, TestFileLimit, ClientId, Thumbprint, Tenant, and **SiteOwner** (a valid user UPN in the client tenant, e.g. a Global Admin — required for the script to create the archive site under app-only auth). Leave `DryRun: true` for the first pass.

## 6. Test the connection (PowerShell 7)

```powershell
Connect-PnPOnline -Url "https://CLIENTTENANT.sharepoint.com/sites/SOURCE_SITE" `
    -ClientId "YOUR_CLIENT_ID" -Thumbprint "YOUR_THUMBPRINT" -Tenant "CLIENTTENANT.onmicrosoft.com"
Get-PnPWeb
```

If this 401s, diagnose with a decoded token rather than guessing:
```powershell
Get-PnPWeb -ErrorAction SilentlyContinue
Get-PnPAccessToken -ResourceTypeName SharePoint
```
Paste the token into https://jwt.ms and check:
- `roles` contains `Sites.FullControl.All`
- `aud` is `00000003-0000-0ff1-ce0b-000000000000` (SharePoint resource) — if it shows `graph.microsoft.com` instead, you grabbed a cached Graph token; call `Get-PnPWeb` first to force a SharePoint-scoped token, then re-pull.

## 7. Run the archive script

```powershell
.\Archive-SharePointFiles.ps1
```

Review the dry-run output/log. When satisfied, set `"DryRun": false` in config.json, start with a small `TestFileLimit` (e.g. 10) to confirm a live run works cleanly, then scale up.

---

## Troubleshooting quick reference

| Symptom | Cause | Fix |
|---|---|---|
| `Register-PnPEntraIDApp` param error on `-Interactive` | Cmdlet renamed/changed across PnP versions | Drop `-Interactive`, run `Get-Command Register-PnPEntraIDApp -Syntax` to check actual params |
| "Application already exists" | Leftover from a prior partial run | Reuse existing app's ClientId, or delete it in Entra portal and rerun |
| `Get-PnPList`/`Get-PnPWeb` → 401 Unauthorized | Consent not yet propagated, or genuinely not granted | Check API permissions green check, grant if missing, wait up to 30 min |
| `Connect-SPOService`/`Get-SPOTenant` not recognized | Wrong PowerShell edition (SPO module is Desktop-only) | Run in Windows PowerShell 5.1, not PowerShell 7 |
| `Connect-PnPOnline`/`Get-PnPAccessToken` not recognized | Wrong PowerShell edition (PnP.PowerShell is Core-only, 2.x+) | Run in PowerShell 7, not Windows PowerShell |
| `Connect-SPOService` → "No valid OAuth 2.0 authentication session exists" | Running SPO module under PowerShell 7 instead of 5.1 | Switch to Windows PowerShell 5.1 |
| `Get-PnPAccessToken` shows `aud: graph.microsoft.com` | Returned a cached Graph token, not SharePoint | Call `Get-PnPWeb` (or similar SPO cmdlet) first, then re-pull with `-ResourceTypeName SharePoint` |
| `New-PnPSite` → "You need to set the owner in App-only context" | No interactive user context to default to under app-only auth | Pass `-Owner <validUserUPN>` (config's `SiteOwner` field) |
| `Access denied` immediately on a **brand-new** archive site, even though the app has `Sites.FullControl.All` | Permission propagation lag for the newly created site specifically (separate from the consent-propagation gotcha above) | Wait ~10 min after site creation, retry |
| `Access denied` when copying into a newly created site, mentions folder creation | Building paths off the library's **display name** (e.g. "Documents") instead of its real folder (e.g. "Shared Documents") — tries to create a folder outside any list | Always resolve `Get-PnPList -Includes RootFolder` and use `.RootFolder.ServerRelativeUrl`, never the config's library name string |
| `Copy-PnPFile` error shows a **doubled URL** (site URL appears twice) | `-SourceUrl` was passed as absolute; the cmdlet always prepends the connected site's URL | Keep `-SourceUrl` server-relative; only `-TargetUrl` should be absolute (that's what triggers the cross-site copy job) |
| "Copy verification failed" right after a successful-looking copy | `Copy-PnPFile` triggers an async job (`CreateCopyJobs`) that hasn't landed yet — checking immediately is too early | Batch: trigger all copies, wait once (~30s), verify afterward — don't block per-file |
| "Copy verification failed" persists even after confirming the file exists via a manual `Get-PnPFile` | Two possible causes seen: (a) juggling multiple named `-Connection` objects mid-loop got unreliable, (b) `Split-Path -Parent` returns **backslashes** on Windows even for forward-slash SharePoint paths, silently breaking the URL | Use one plain default connection per site per phase (no mid-loop reconnects); always `-replace '\\','/'` on any `Split-Path` result used in a SharePoint path |
| "Error triggering copy" with `SPMigrationQosException` / "system cannot find the file specified", even though the file demonstrably exists | File or folder name contains `#` or `..` — SharePoint's cross-site copy-job API treats `#` as a URL fragment delimiter and truncates the path before it ever resolves the source | Rename the offending file/folder (remove `#` and `..`), then rerun — the file stays untouched in source until then, no data risk |
| Full run finishes (or is interrupted) but `archive-log.csv` doesn't reflect everything that happened | The script only writes the log **once, at the very end** of the entire run (all rows buffered in memory until then) — a crash or closed window loses the whole run's audit trail even though real copies/deletes already happened | Don't trust the log alone after any interrupted run — use `Verify-ArchiveReconciliation.ps1` to compare source vs. archive directly. Fix long-term: change the script to append each row immediately instead of buffering. |
| Two windows both say "Connecting to archive site..." and go silent for several minutes with no error | SharePoint Online throttling when multiple full-scale jobs run against the same tenant at once — PnP.PowerShell retries with silent exponential backoff | Wait 10-15 min before assuming it's hung; if genuinely stuck, stagger the jobs instead of running everything concurrently |
