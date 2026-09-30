# Scripts Reference

Syntax, parameters, and examples for every PowerShell script in this project. All scripts require **PowerShell 7** (`pwsh`) and the `PnP.PowerShell` module (`Archive-ToM365ColdStorage.ps1` additionally needs the `Microsoft.Graph.*` modules — see its own section below). Run everything from this folder so relative paths (config files, log outputs) resolve correctly.

---

## 1. Archive-SharePointFiles.ps1

**What it does:** copies files older than a configurable age threshold from a source SharePoint library into a separate Archive site collection, then deletes the originals once the copy is verified. Creates the Archive site if it doesn't exist yet.

### Syntax

```powershell
.\Archive-SharePointFiles.ps1 [-ConfigPath <path>]
```

| Parameter | Required | Default | Notes |
|---|---|---|---|
| `-ConfigPath` | No | `.\config.json` | Path to the site's config JSON (see `config.template.json`) |

Behavior is controlled entirely by the config file's `DryRun` and `TestFileLimit` fields — there's no separate `-WhatIf` switch on this script.

- `DryRun: true` — logs what it *would* do, changes nothing.
- `DryRun: false` — actually copies and deletes.
- `TestFileLimit: 100` — only processes the 100 oldest eligible files (safe test batch).
- `TestFileLimit: 0` — processes every eligible file (full run).

### Examples

```powershell
# Dry run against Creative using the default config.json - review before trusting it
.\Archive-SharePointFiles.ps1

# Dry run against a specific site's config
.\Archive-SharePointFiles.ps1 -ConfigPath .\config-media.json

# (after setting DryRun:false and TestFileLimit:0 in config-digital.json)
.\Archive-SharePointFiles.ps1 -ConfigPath .\config-digital.json
```

### Output

Prints progress live, writes every action to the CSV named in the config's `LogPath`, and ends with a summary block including Eligible/Processed/Archived/Errors counts **and a by-year file inventory** (last 5 calendar years + an "Older than" bucket, count + size in GB) for the whole source library — regardless of what was actually archived that run.

---

## 2. Verify-ArchiveReconciliation.ps1

**What it does:** read-only ground-truth check. Compares the source and archive libraries directly (ignores `archive-log.csv` entirely) and classifies every file as fully archived, copied-but-not-deleted, or not yet touched. Safe to run anytime, including while an archive run is live in another window.

### Syntax

```powershell
.\Verify-ArchiveReconciliation.ps1 [-ConfigPath <path>] [-ReportPath <path>]
```

| Parameter | Required | Default | Notes |
|---|---|---|---|
| `-ConfigPath` | No | `.\config.json` | Same config file the archive script for that site uses |
| `-ReportPath` | No | `.\reconciliation-<configname>.csv` | Where to write the detailed report |

### Examples

```powershell
# Check Creative
.\Verify-ArchiveReconciliation.ps1 -ConfigPath .\config.json

# Check Digital, custom report location
.\Verify-ArchiveReconciliation.ps1 -ConfigPath .\config-digital.json -ReportPath .\digital-check.csv
```

### Output

Prints a summary count per status (`ARCHIVED_CONFIRMED`, `COPIED_NOT_DELETED`, `NOT_YET_ARCHIVED_ELIGIBLE`, `NOT_YET_ARCHIVED_TOO_RECENT`), a full row-by-row CSV report, and a **by-year file inventory** of the source library.

Use this whenever you don't trust the log (e.g. after a window crashed or was closed mid-run) — it tells you what's actually true on the SharePoint side, not what the log claims happened.

---

## 3. Rename-ProblemFiles.ps1

**What it does:** finds and renames files/folders whose names contain characters known to break the copy process (`#`, `%`, leading/trailing spaces, trailing periods, runs of `..`). Safe by default — dry run unless you pass `-Execute`.

### Syntax

```powershell
.\Rename-ProblemFiles.ps1 -ConfigPath <path> [-Execute]
```

| Parameter | Required | Default | Notes |
|---|---|---|---|
| `-ConfigPath` | **Yes** | — | Reuses the site's existing config (for site URL, library, and credentials) |
| `-Execute` | No | off (dry run) | Without this, it only reports what *would* be renamed |

### Examples

```powershell
# Dry run - see what would be renamed, nothing changes
.\Rename-ProblemFiles.ps1 -ConfigPath .\config-digital.json

# Actually rename the flagged files/folders
.\Rename-ProblemFiles.ps1 -ConfigPath .\config-digital.json -Execute
```

### Output

Prints each rename (or would-rename) live, writes a `rename-log-<configname>.csv`, and prints a count summary. Renames deepest paths first so a folder rename never orphans an already-computed child path.

**Don't run this against a site while an archive run is actively in progress against the same site** — renaming a file mid-copy can confuse the in-flight job.

---

## 4. Archive-ToM365ColdStorage.ps1

**What it does:** archives files into Microsoft's native **Microsoft 365 Archive** cold-storage tier (see explainer below) rather than moving them to a second site. Files stay at their original URL — only their storage tier changes.

### Prerequisites (once per client tenant)

1. `Set-SPOTenant -AllowFileArchive $true` — run interactively via SPO Management Shell (Windows PowerShell 5.1), cannot be done app-only.
2. The app registration needs the Microsoft **Graph** application permission `Sites.ReadWrite.All` (separate from the SharePoint-specific permission used by the other scripts) — admin-consented, same propagation-delay caveat (5–30 min) applies.
3. `Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Sites, Microsoft.Graph.Files -Scope CurrentUser -Force`

Full step-by-step is in the comment block at the bottom of the script itself.

### Syntax

```powershell
.\Archive-ToM365ColdStorage.ps1 -ConfigPath <path> [-WhatIf]
```

| Parameter | Required | Default | Notes |
|---|---|---|---|
| `-ConfigPath` | **Yes** | — | See `config-m365archive.template.json` — lists every site + library in scope, since this script covers multiple sites in one run |
| `-WhatIf` | No | off | With this switch, nothing is archived - just reports what would happen |

### Examples

```powershell
# Preview only - see what would be archived across every listed site
.\Archive-ToM365ColdStorage.ps1 -ConfigPath .\config-m365archive.json -WhatIf

# Actually archive
.\Archive-ToM365ColdStorage.ps1 -ConfigPath .\config-m365archive.json
```

### Output

Per-site progress and a **by-year file inventory per site**, plus a combined total across all sites in the final summary. Log written to the config's `LogPath`.

---

## What is "Cold Storage" (Microsoft 365 Archive)?

Microsoft 365 Archive is Microsoft's built-in file-level cold-storage tier for SharePoint/OneDrive, currently rolling out (public preview now, Microsoft's targeted GA is July 2026). It's conceptually similar to Exchange Online's "Online Archive" for mailboxes, but for files.

**How it's different from the site-copy approach** (`Archive-SharePointFiles.ps1`):

| | Site-copy (this project's main script) | Microsoft 365 Archive (cold storage) |
|---|---|---|
| File location | Moves to a new URL (separate Archive site) | Stays at its **original URL** |
| Permissions | New permissions on the archive site (usually just admins) | **Unchanged** - same people can still see/reactivate it |
| Search/eDiscovery | Only visible if someone knows to look in the archive site | Still shows up in normal search/eDiscovery |
| Storage cost | Counts against normal SharePoint storage | Cheaper cold-storage tier |
| Who can undo it | Someone with access to the archive site, manually | The file's own users, via "Reactivate" |
| Reversal effort | Move the file back manually | One click / one API call, then wait for rehydration |

In short: site-copy is better when you want files physically out of the way (e.g. off a client's main site, into something an MSP manages separately). Cold storage is better when the *same* users should still be able to find and reactivate their own old files without anyone doing manual work.

### How to get a file back from Cold Storage

**For an end user (SharePoint/OneDrive UI):**

1. Find the file where it's always lived (it doesn't move) - it'll show an "Archived" indicator.
2. Right-click (or the `⋯` menu) → **Reactivate**.
3. Open and use the file normally once reactivation completes.

**Timing:**
- Reactivated within the first **7 days** of being archived → instant.
- After 7 days → can take **up to 24 hours** to rehydrate from cold storage. The person who reactivated it gets an email when it's ready.
- Reactivating a large **folder** (recursive) → scheduling alone can take up to 24 hours, and the full process up to **48 hours** for very large folders.

**For bulk/admin reactivation (Microsoft Graph API):**

```
POST https://graph.microsoft.com/beta/sites/{siteId}/drive/items/{itemId}/unarchive
```

(equivalent form: `POST https://graph.microsoft.com/beta/drives/{driveId}/items/{itemId}/unarchive`)

If the file had been archived less than 7 days, the response returns immediately with no further status needed. If longer, the response indicates it's now rehydrating, and it'll be usable once that completes (same up-to-24h window as the UI path).

There's no ready-made reactivation script in this project yet — say the word if you want one built (single-file or bulk-by-folder), following the same `-WhatIf`-safe pattern as the archive script.

**One limitation worth knowing:** once a file is reactivated, it can't be re-archived again for about **120 days** (a Microsoft-imposed cooldown) — so reactivating isn't something to do casually if the plan is to keep it archived long-term.

Sources:
- [End user experience in Microsoft 365 Archive - Microsoft Learn](https://learn.microsoft.com/en-us/microsoft-365/archive/archive-end-user?view=o365-worldwide)
- [Developer guidance for Microsoft 365 Archive - Microsoft Learn](https://learn.microsoft.com/en-us/microsoft-365/archive/developer-guidance?view=o365-worldwide)
- [SharePoint File-Level Archiving and the Microsoft Graph APIs](https://office365itpros.com/2026/05/12/file-level-archiving-sdk/)
- [How File-Level Archiving Works for SharePoint Online](https://office365itpros.com/2026/05/05/file-level-archiving-spo/)
