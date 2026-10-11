# Solar Monitor Worker setup

This Worker collects FoxESS inverter history and Amber buy (general) and sell (feed-in) prices every five minutes, stores them in Cloudflare D1, and serves read-only JSON to the dashboard. It does not control the inverter. Collection starts after deployment; this setup does not backfill earlier data. Readings and prices older than 90 days are deleted during collection.

## 1. Create the database and fill in its ID

1. In Cloudflare, open **Storage & databases → D1 SQL Database** and create `commonsense-solar-readings`.
2. Copy the database ID from its details page.
3. In GitHub, open [`worker/wrangler.toml`](https://github.com/AnthonyCarterCC/commonsense-geeking/blob/main/worker/wrangler.toml), choose **Edit**, and replace `REPLACE_WITH_D1_DATABASE_ID` with that ID. Keep the quotes. Commit the edit.
4. Open the new D1 database's **Console** in Cloudflare, paste all of [`worker/schema.sql`](https://github.com/AnthonyCarterCC/commonsense-geeking/blob/main/worker/schema.sql), and run it. This creates the tables; there is no CSV to upload.

## 2. Connect the GitHub repository to Workers

1. In Cloudflare, go to **Workers & Pages → Create application → Import an existing Git repository**. Select `AnthonyCarterCC/commonsense-geeking` and branch `main`. Choose the existing repository; do not select a Cloudflare sample template or create a new Git repository.
2. Set the project root directory to `worker`. Leave the build command empty; if asked for a deploy command, enter `npx wrangler deploy`.
3. Deploy the Worker. Its `wrangler.toml` configures the five-minute Cron Trigger, D1 binding named `DB`, allowed website origin, and 41.93 kWh nominal battery capacity.

## 3. Add credentials and the Amber site ID

In the new Worker, open **Settings → Variables and Secrets**. Add these as Worker **secrets**. First revoke/rotate the old credentials from the supplied example files. Never commit the replacement values or put them in `solar/index.html`.

- `FOXESS_TOKEN` — newly generated FoxESS API token
- `FOXESS_DEVICE_SN` — inverter serial number
- `AMBER_TOKEN` — newly generated Amber API token

Add `AMBER_SITE_ID` as a regular Worker variable, using the ID for the correct property from your Amber account. The `ALLOWED_ORIGIN` and `BATTERY_CAPACITY_KWH` variables are already in `wrangler.toml`.

Enable the `workers.dev` subdomain if Cloudflare prompts you. Your Worker address will look like `https://commonsense-solar-monitor.<your-account-subdomain>.workers.dev`.

## 4. Point the dashboard at the Worker

In GitHub, edit [`solar/index.html`](https://github.com/AnthonyCarterCC/commonsense-geeking/blob/main/solar/index.html). Immediately before its main inline `<script>`, add this line, replacing the example host with the actual Worker address:

```html
<script>window.SOLAR_API_BASE = "https://commonsense-solar-monitor.<your-account-subdomain>.workers.dev";</script>
```

Commit the edit. The live dashboard will then read `/api/health`, `/api/readings`, and `/api/prices` from the Worker.

## Check the connection

Open `https://<your-worker-address>/api/health`. `configured` should be `true`; after the first five-minute collection, `latest` should contain a timestamp. The D1 database stores FoxESS samples and Amber price intervals for 90 days. The API is public by design, so anyone who can reach it can read the published energy history. Do not collect or store information you want to keep private. Amber price planning is an estimate only; the Worker never sends charge commands to the inverter.

## API endpoints

- `/api/health` - `configured`, `amberConfigured` and the timestamp of the `latest` reading.
- `/api/readings?hours=N` - inverter samples (battery, solar, load, grid import, grid export, charge, discharge).
- `/api/prices?hours=N` - Amber price intervals, past and forecast.

## Sell (feed-in) prices

The collector stores Amber's `general` (buy) and `feedIn` channels; the sell channel is stored as `feed-in`, and `/api/prices` returns `channelType` for every row. Amber reports feed-in `perKwh` as a negative number when you are paid, and it is stored exactly as received; the dashboard flips the sign. On the first run after this change (no `feed-in` rows yet) the collector also requests the previous 96 intervals (48 hours) so today's sell prices exist; if Amber rejects that window it falls back to the normal two intervals. Collection now writes roughly twice as many price rows per run.
