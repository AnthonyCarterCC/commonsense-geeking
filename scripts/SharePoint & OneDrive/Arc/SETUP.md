# Setup Guide — SharePoint Archive Script

One-time setup per client tenant. Takes ~15 minutes.

## 1. Register an Entra ID app

1. In the client's tenant: **Entra admin center** → **App registrations** → **New registration**.
2. Name: `SPO-Archive-Automation` (or similar). Single tenant. No redirect URI needed.
3. Note the **Application (client) ID** and **Directory (tenant) ID**.

## 2. Add API permissions

App registration → **API permissions** → **Add a permission** → **SharePoint** → **Application permissions**:

- `Sites.FullControl.All` (needed to create the Archive site collection)

Then **Grant admin consent** for the tenant (requires a Global/SharePoint admin).

> If you'd rather not grant FullControl, `Sites.Manage.All` is enough once the Archive
> site already exists — you'd just need to create the site manually once via the
> SharePoint admin center instead of letting the script do it.

## 3. Certificate auth (recommended over client secrets)

App-only PnP connections need a certificate, not a password.

```powershell
# Generate a self-signed cert and register it with the app in one step:
Register-PnPEntraIDAppForInteractiveLogin -ApplicationName "SPO-Archive-Automation" `
    -Tenant "CLIENTTENANT.onmicrosoft.com" -Interactive
```

Or, simpler — use PnP's built-in setup cmdlet which creates the app registration,
cert, and permissions for you in one go:

```powershell
Register-PnPAzureADApp -ApplicationName "SPO-Archive-Automation" `
    -Tenant "CLIENTTENANT.onmicrosoft.com" `
    -Store CurrentUser -SharePointApplicationPermissions "Sites.FullControl.All" `
    -Interactive
```

This outputs a `ClientId` and `Thumbprint` — copy both into `config.json`.

## 4. Install PnP.PowerShell

```powershell
Install-Module -Name PnP.PowerShell -Scope CurrentUser -Force
```

## 5. Fill in config.json

Edit `config.json` (in this same folder) with the client's actual values:

| Field | Value |
|---|---|
| `TenantAdminUrl` | `https://CLIENTTENANT-admin.sharepoint.com` |
| `SourceSiteUrl` | The site collection you're archiving from |
| `SourceLibrary` | Usually `Documents`, but confirm |
| `ArchiveSiteUrl` | Where the archive should live (script creates it if missing) |
| `ClientId` / `Thumbprint` / `Tenant` | From step 3 |
| `ArchiveThresholdYears` | `10` for this test run |
| `TestFileLimit` | `100` for this test run |
| `DryRun` | Leave `true` for the first pass |

## 6. Run it

```powershell
.\Archive-SharePointFiles.ps1
```

First pass: `DryRun: true` — it will log everything it *would* do (including whether
it needs to create the Archive site) without touching any files. Review
`archive-log.csv`.

Once that looks right, set `"DryRun": false` and re-run to actually move the 100
test files.

## Notes / limitations to flag to the client

- Version history isn't preserved by `Copy-PnPFile` — only the current version moves.
  If the client needs full version history archived, that's a bigger lift (needs the
  Graph API version endpoint, file by file).
- Files currently checked out or locked will error on delete — logged as `ERROR`,
  original stays in place, safe to re-run.
- The Archive site is deliberately not added to anyone's OneDrive sync scope — it's
  browser-access only unless someone manually chooses to sync it.
