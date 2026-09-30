# SharePoint Archive Automation — Project Handoff

Paste or attach this file into a new Claude conversation (any device) to resume this project with full context.

## What this project is

Two separate archiving approaches, both live in this folder:

1. **`Archive-SharePointFiles.ps1`** — copies old files into a second, dedicated Archive site collection you manage (e.g. `Creative5yrArchive`). Files move to a new URL. This is the one that's been run in production so far.
2. **`Archive-ToM365ColdStorage.ps1`** — uses Microsoft's native Microsoft 365 Archive (cold-storage) feature via the Graph beta API. Files stay at their original URL/permissions but move to a cheaper storage tier; users can self-reactivate. Built but **not yet run against any client** — see "Not yet started" below.

Both are run per-source-site, sharing one Entra ID app registration (certificate-based app-only auth) within a tenant, though the M365 Archive script needs an additional Graph permission added to that same app (see its embedded onboarding notes).

## Status as of 2026-08-06 (this session)

**velocityairau tenant**: onboarded via the wizard (`Manage-ArchiveProfiles.ps1`), `config-VA.json`. `Connect-PnPOnline`/`Get-PnPWeb` confirmed working — ClientId `04fde341-9fe5-4286-9744-7e548daea2b0`, Thumbprint `14AEFC943DCCEBF72E581EEFA5481545AE9B14DE`. No archive run started yet.

**Wizard improvement this session**: certificate-to-app attachment no longer requires the Entra portal. When registering a new app fails because it already exists, the wizard now generates a fresh certificate locally and attaches it to the existing app automatically via Microsoft Graph (`Update-MgApplication`), rather than asking for a manual "Certificates & secrets > Upload certificate" step. This is what finally unblocked velocityairau after a certificate got deleted mid-setup — see "Bugs found" #9/#10 below.

**Wizard bug fixed this session**: `Remove-UnusedCertificates` ([D] menu) previously judged a certificate "unused" purely by whether a *saved profile* referenced its thumbprint — a cert just registered in the current session (recorded in the registry) but not yet saved into a profile looked identical to a genuinely dead one, and `[A] All unused` would delete it. This is exactly what deleted velocityairau's first working certificate. Fixed: certs created in the last 30 minutes with no profile reference now require individual confirmation and are excluded from `[A] All unused`.

**Visibility overhaul this session (all four action scripts)**: every script that connects or scans a library used to go silent for long stretches with no way to tell "connected," "still scanning," and "actually hung" apart (surfaced when velocityairau's first full run sat unchanged for 90 minutes). Now, in `Archive-SharePointFiles.ps1`, `Archive-ToM365ColdStorage.ps1`, `Verify-ArchiveReconciliation.ps1`, and `Rename-ProblemFiles.ps1`:
- Every connection (`Connect-PnPOnline`/`Connect-MgGraph`) is followed by a real round-trip call (`Get-PnPWeb`/`Get-MgOrganization`) and prints `[HH:mm:ss] Connected - '<name>' responded in X.Xs` - proves the connection actually works, not just that the object was constructed.
- Every phase prints a `[HH:mm:ss] ==> ...` banner when it starts.
- Large enumerations (file scans) print progress every 500 items as they stream, instead of going silent until the whole library is read.
- Per-item loops (folder creation, copy trigger, verify + retries, delete, rename, per-site M365 archive) print `[HH:mm:ss] [i/total] ...` on every item.
- Also fixed: the "(test limit applied)" label in `Archive-SharePointFiles.ps1` used to appear even on full runs with no limit - it now only shows when a limit actually cut the run short.

**Progress throttled (same session, follow-up)**: the per-item progress above was originally every single item / every 500 scanned, which turned into continuous scroll on large runs (390k+ files). All four scripts now use a shared `New-ProgressGate`/`Test-ProgressGate` pattern: a success line prints at most once every 5000 items OR every 5 seconds (whichever comes first), plus always on the very last item. Errors are never throttled - they print immediately, every time, regardless of the gate.

**New script this session: `Remove-EmptyFolders.ps1`** - `Archive-SharePointFiles.ps1` copies files out and deletes the originals, but never touches the now-empty folder structure left behind in the SOURCE library. This new script cleans that up: finds folders with zero files anywhere in their subtree, removes only the shallowest folder in any fully-empty branch (deleting it takes its empty subfolders with it), and skips the library root and system folders like `Forms`. Dry-run by default, `-Execute` to apply, same config.json reuse and visibility/progress-gate pattern as the rest of the toolset. Deletes via `Remove-PnPListItem -Identity <item.Id> -Recycle` (by item ID, not a reconstructed path) specifically to avoid the server-relative/site-relative path mismatches that have caused real bugs elsewhere in this project (see bugs #2/#5/#7 below) - removed folders land in the site recycle bin, not permanently deleted. Not yet run against any client - run it after an archive run completes, against the same config used for that run.

**platinummc tenant — site-copy approach (`Archive-SharePointFiles.ps1`), full production runs:**

- **Creative**: full run complete. 12,344 eligible, 12,344 processed, **12,344 archived, 0 errors**. Clean.
- **Digital**: full run complete. 6,679 eligible, 6,679 processed, **6,609 archived, 70 errors**. All 70 were the same root cause (`#`/`..` in one legacy "saved webpage" folder name breaking the copy-job API - see "Bugs found" #7 below). **Fixed**: ran `Rename-ProblemFiles.ps1 -Execute` against Digital, which renamed the offending folder and 5 files with `%` in their names (those 5 needed a second fix - see #8 below). Digital is ready for a rerun to pick up these now-unblocked files; not yet re-run as of this note.
- **Media**: full run complete (ran overnight). Across all runs logged for this site (small tests + the full run, cumulative): **22,261 archived, 43 errors**. Error breakdown: 36 were `No such host is known` (transient DNS/network blip mid-run, not a real problem - those files are just untouched and will pick up on a rerun), 3 were genuinely checked-out/locked files (skipped safely, per the script's documented behavior), 2 were a network timeout, 2 were a WAF "request blocked" response (likely a brief throttling/security-rule hiccup). **None of these indicate data loss** - the copy-before-delete design means an interrupted file is simply left untouched in source.

**Cleanup script added this session**: `Rename-ProblemFiles.ps1` - finds and renames files/folders with `#`, `%`, leading/trailing whitespace, trailing periods, or `..` in their names (see "Bugs found" #7 and #8). Tested and working against Digital.

**Reporting added to all four scripts**: every script now prints a file inventory broken down by the last 5 calendar years (count + size in GB), plus an "Older than" bucket - see `Scripts-Reference.md` for exact output format.

**Known systemic issue (affects both scripts equally, not yet fixed):** the log is built entirely in memory and only written to CSV once, at the very end of a run (`Export-Csv ... -Append` is the second-to-last line of both scripts). If a run is interrupted (throttling, closed window, crash) before reaching that line, everything it actually did — including real copies and real deletions — is invisible in the log. This is exactly what happened with Creative's first attempted full run (453 files were found archived on disk with zero log rows for them). **Fix, not yet applied**: change both scripts to append each file's log row immediately after processing it, rather than buffering the whole run in memory. Do this before the next full run of either script.

**Cert**: same `.pfx`/`.cer` in this folder works for `Archive-SharePointFiles.ps1` (SharePoint app-only permission). For `Archive-ToM365ColdStorage.ps1`, the *same app registration* can be reused, but needs the Microsoft **Graph** application permission `Sites.ReadWrite.All` added and re-consented — that's a different permission system to the SharePoint-specific one already granted, see the script's embedded onboarding notes for exact steps.

**Not yet started:** Microsoft 365 Archive (cold-storage) approach has not been tested against any client yet. Per-tenant prerequisite before it can run anywhere: `Set-SPOTenant -AllowFileArchive $true`, run interactively via SPO Management Shell (cannot be done app-only). Test with `-WhatIf` first, same pattern as the DryRun convention in the other script.

## Files in this folder

- `Archive-SharePointFiles.ps1` — site-to-site copy archive script (accepts `-ConfigPath`)
- `Archive-ToM365ColdStorage.ps1` — Microsoft 365 native cold-storage archive script (accepts `-ConfigPath`, `-WhatIf`); full onboarding steps are in a comment block at the bottom of the file
- `Verify-ArchiveReconciliation.ps1` — read-only script, compares source vs. archive library directly (ignores the log entirely) and classifies every file as `ARCHIVED_CONFIRMED` / `COPIED_NOT_DELETED` / `NOT_YET_ARCHIVED_*`. Safe to run anytime, including alongside a live archive run.
- `Rename-ProblemFiles.ps1` — finds/renames files or folders with `#`, `%`, leading/trailing whitespace, trailing periods, or `..` in the name. Dry run by default, `-Execute` to apply.
- `Scripts-Reference.md` — **syntax, parameters, and examples for every script above**, plus a full explainer on what Microsoft 365 Archive (cold storage) is and how to reactivate a file from it.
- `config.json` / `config-media.json` / `config-digital.json` — per-site configs for `Archive-SharePointFiles.ps1` (Creative / Media / Digital), all currently set to `TestFileLimit: 0, DryRun: false`
- `config.template.json` — blank template for onboarding a new source site under the site-copy approach
- `config-m365archive.template.json` — blank template for onboarding a client under the M365 cold-storage approach (lists multiple sites/libraries per config, since that script covers many sites in one run)
- `SPO-Archive-Setup-Guide.md` — step-by-step setup + troubleshooting reference (site-copy approach)
- `SETUP.md` — earlier/alternate setup notes (predates SPO-Archive-Setup-Guide.md, kept for reference, some duplication)
- `PROJECT-HANDOFF.md` — this file
- `archive-log.csv` / `archive-log-media.csv` / `archive-log-digital.csv` — per-site audit logs for the site-copy script (only written once, at the very end of each run — see "Known systemic issue" above)
- `rename-log-config-digital.csv` — audit log from `Rename-ProblemFiles.ps1`'s run against Digital
- `SPO-Archive-Automation.pfx` / `.cer` — the app's certificate (works for both scripts; M365 script additionally needs a Graph permission added to the same app)
- `SPO-Archive-Project-Backup-*.zip` — dated full-project backups

## Key facts (platinummc tenant)

- Tenant: `platinummc.onmicrosoft.com`
- App registration: `SPO-Archive-Automation`
- ClientId: `6d586e8a-1308-4cd1-aa8e-721b9f5cb16f`
- Thumbprint: `044447ECF24E7C804EA33E3FA7DDB8949C42CE0F`
- Site owner used for new archive sites: `admin@platinummc.onmicrosoft.com`
- Creative: `https://platinummc.sharepoint.com/sites/Creative` → `Creative5yrArchive` — **done**
- Media: `https://platinummc.sharepoint.com/sites/Media` → `Media5yrArchive` — **unconfirmed, verify before trusting**
- Digital: `https://platinummc.sharepoint.com/sites/Digital` → `Digital5yrArchive` — **done, 70 files need the folder-rename fix**
- Threshold: 5 years across all three sites

## Bugs found and fixed (site-copy script, all resolved)

1. `New-PnPSite` under app-only auth needs `-Owner` — no interactive user context to default to.
2. Library display name ≠ actual URL folder ("Documents" vs. real root `Shared Documents`) — always use `Get-PnPList -Includes RootFolder` / `.RootFolder.ServerRelativeUrl`, never the display name.
3. `Copy-PnPFile`: `-SourceUrl` must stay server-relative, `-TargetUrl` must be absolute — mixing these breaks the cross-site async copy-job API.
4. The copy job is asynchronous — don't verify immediately after triggering; batch (trigger all → wait → verify all).
5. `Split-Path -Parent` returns backslash paths on Windows even from forward-slash input — always `-replace '\\', '/'` before using in a SharePoint URL.
6. Don't juggle multiple named PnP connections mid-loop — reconnect with the plain default connection at clean phase boundaries instead.

## New issues found this session (now fixed via `Rename-ProblemFiles.ps1`)

7. **`#` and `..` in file/folder names break `Copy-PnPFile`'s cross-site copy-job API.** SharePoint's copy-job resolves the source URL and truncates at `#` (treated as a URL fragment delimiter), producing "system cannot find the file specified" even though the file demonstrably exists. Affects only files/folders with these characters in the path — 70 such files in Digital, all in one legacy "saved webpage" folder. Fix: `Rename-PnPFolder`/`Rename-PnPFile` to strip these characters, then rerun the archive script.

8. **`%` in a file name breaks `Rename-PnPFile`'s own path resolution** (a *different* bug from #7, discovered while fixing it). A literal `%` gets misread by the underlying REST call as the start of a `%XX` escape sequence, resolving to the wrong path ("File Not Found"). Manually pre-escaping it as `%25` makes it *worse* (then it looks for a literal `%25` substring, which doesn't exist either). Fix: use `Move-PnPFile` (move to the same parent folder under the new name) instead of `Rename-PnPFile` for files with `%` in the name — a different code path that resolves the path correctly. `Rename-PnPFolder` was unaffected (only tested with `#`, not yet confirmed with `%` in a folder name).

9. **`Export-PfxCertificate`/`Export-Certificate` fail with "Cannot find path Cert:\...\<thumbprint>"** if `Register-PnPEntraIDApp` wasn't called with `-Store CurrentUser` — the generated certificate is created but never lands in the Windows cert store, so nothing local exists to export. Fix: always include `-Store CurrentUser`.

10. **Attaching a certificate to an app registration no longer requires the Entra portal.** `Manage-ArchiveProfiles.ps1` now does this via Microsoft Graph (`Update-MgApplication` with an appended `KeyCredentials` entry) whenever `Register-PnPEntraIDApp` fails because the app already exists — it generates a new local certificate, looks up the existing app's ClientId via `Get-MgApplication`, and attaches the cert directly. Requires the `Microsoft.Graph.Applications` module (auto-installed if missing) and one interactive Global Admin sign-in with `Application.ReadWrite.All` scope — the same kind of one-time browser consent already used for the app registration step itself, not a new barrier.

## Earlier troubleshooting knowledge (setup phase, still valid)

1. `Register-PnPAzureADApp` is aliased to `Register-PnPEntraIDApp` — doesn't accept `-Interactive`; just omit it, browser launches automatically.
2. "Application already exists" — check Azure Portal → App registrations before re-registering with a new name.
3. **PowerShell edition split**: `PnP.PowerShell` (2.x+) is Core-only (PowerShell 7); `Microsoft.Online.SharePoint.PowerShell` is Desktop-only (Windows PowerShell 5.1). Can't coexist in one session.
4. A 401 right after granting Entra admin consent is often just propagation delay (5–30+ min).
5. Check `Get-SPOTenant | Select DisableCustomAppAuthentication` — if `True`, run `Set-SPOTenant -DisableCustomAppAuthentication $false`.
6. To diagnose a persistent 401/Access Denied, decode the token via `Get-PnPAccessToken -ResourceTypeName SharePoint` → paste into https://jwt.ms → check `roles` and `aud`.
7. **Running multiple full-scale jobs against the same tenant concurrently can trigger SharePoint throttling** — PnP.PowerShell retries silently with backoff, which looks exactly like a hang (no error, no output, sometimes for 10+ minutes). Give it time before assuming something's broken; if it's a real hang, stagger the jobs instead of running everything at once.

## Next steps to pick up

1. **Rerun Digital** (`.\Archive-SharePointFiles.ps1 -ConfigPath .\config-digital.json`) now that the problem names are fixed — the ~75 previously-blocked files should go through cleanly this time.
2. **Rerun `Verify-ArchiveReconciliation.ps1` against Media** to confirm the 43 error'd files (mostly a transient DNS blip, a few checked-out files) are genuinely still sitting untouched in source, then rerun Media's archive script to pick them up.
3. **Fix the log-only-at-end design** in both archive scripts before the next full run anywhere — append per-file instead of buffering (see "Known systemic issue" above).
4. **Decide whether to pursue the M365 cold-storage approach** as an alternative/addition to the site-copy approach for future clients — it's built and ready to test with `-WhatIf`, but tenant-wide `AllowFileArchive` needs enabling first (interactive, SPO Management Shell). See `Scripts-Reference.md` for what cold storage is and how reactivation works.
5. Onboard the next client using either `config.template.json` (site-copy) or `config-m365archive.template.json` (cold-storage) + the relevant setup guide.
6. Consider running `Rename-ProblemFiles.ps1` proactively against Creative and Media too, even though no failures surfaced there yet — same character classes could be lurking unarchived files that just haven't been reached by a full run yet.
