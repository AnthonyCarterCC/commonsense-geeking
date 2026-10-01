# Solar Monitor Worker setup

This Worker collects FoxESS inverter history and Amber import prices once per hour, stores them in Cloudflare D1, and serves read-only JSON to the dashboard. It does not control the inverter. The dashboard has been set to collect hourly data; it begins collecting after deployment and does not backfill earlier data.

## Deploy from the GitHub repository

1. In Cloudflare, open **Workers & Pages → Create application → Import an existing Git repository**. Choose `AnthonyCarterCC/commonsense-geeking`. Do not select a Cloudflare sample template.
2. Set the Worker project root directory to `worker`. Leave the build command empty and use `npx wrangler deploy` as the deploy command if Cloudflare asks for one.
3. Create a D1 database named `commonsense-solar-readings`. In `wrangler.toml`, replace `REPLACE_WITH_D1_DATABASE_ID` with that database's ID. This ID is a configuration value, not a secret.
4. Initialize the remote database from this directory, or run the equivalent command in a local checkout:

   ```sh
   npx wrangler d1 execute commonsense-solar-readings --remote --file=schema.sql
   ```

5. Add these three values as Worker **secrets** in Cloudflare. First revoke/rotate the old credentials from the supplied example files. Do not commit the replacement values or put them in `solar/index.html`.

   - `FOXESS_TOKEN` — newly generated FoxESS API token
   - `FOXESS_DEVICE_SN` — inverter serial number
   - `AMBER_TOKEN` — newly generated Amber API token

6. Set Worker variables:

   - `AMBER_SITE_ID` — the site ID returned for the correct Amber property
   - `ALLOWED_ORIGIN` — `https://geeking.commonsense.com.au`
   - `BATTERY_CAPACITY_KWH` — `41.93`

   The `wrangler.toml` already sets the last two variables and the hourly Cron Trigger. Keep the D1 binding name `DB`.

7. Deploy the Worker. In its **Settings → Domains & Routes**, enable the `workers.dev` subdomain if Cloudflare has not already enabled it. The resulting Worker URL will look like `https://commonsense-solar-monitor.<your-account-subdomain>.workers.dev`.
8. Update `solar/index.html`: immediately before its main inline script, add the deployed URL:

   ```html
   <script>window.SOLAR_API_BASE = "https://commonsense-solar-monitor.<your-account-subdomain>.workers.dev";</script>
   ```

   Replace the example host with the actual Worker address and commit the change. The dashboard then requests `/api/health`, `/api/readings`, and `/api/prices` from the Worker.

## Check the connection

Open `https://<your-worker-address>/api/health`. `configured` should be `true`; after the first hourly collection, `latest` should contain a timestamp. The public dashboard can read the stored energy history, so avoid collecting or storing any information you do not want public.

The D1 database stores hourly FoxESS samples and Amber price intervals. It does not accept CSV uploads. Amber price planning is an estimate only; this Worker never sends charge commands to the inverter.
