# Solar & Battery dashboard

**Version 2.1** (12 October 2026). See [Release notes](#release-notes).

Read-only dashboard served at https://geeking.commonsense.com.au/solar/. It is a single file (`index.html`, inline CSS and JS) that reads JSON from the Cloudflare Worker in [`../worker`](../worker/README.md); there is no build step.

## What it shows

- **Energy at a glance**: battery state of charge, stored energy, total solar, household load, battery charge/discharge, grid import and the current Amber import price.
- **Battery and solar history**: three aligned graphs over 24 hours, 7 days or 30 days. Battery charge (%) with a dashed 50% line; solar power against household usage (kW); and grid flow as one signed graph with export above the zero line (purple) and import below it (orange). The time axis is real clock time (Sydney), and a gap of more than 30 minutes in collection shows as a break in the lines. Hovering (or touching) any graph shows one bubble with the time, battery %, solar, house usage, grid export and grid import at that point.
- **Electricity cost today**: Amber buy and sell price bars for the Sydney day (history and forecast), estimated cost so far, projection to midnight and the current rate. Net cost is import cost minus export revenue. The chart axis is capped so normal prices stay readable; bars above the cap are red and the peak is noted on the chart. The projection uses your average import/export for each half-hour over the previous three days.
- **Export earnings today**: money earned so far from power sent to the grid (each interval's export kWh x its Amber sell price), kWh exported, average sell rate and projected earnings at midnight. A red warning appears when, after 2:45pm Sydney time, the battery is below 50% and still exporting (using the latest reading, if under 15 minutes old). Thresholds are in `renderDailyCost`.

## Data source

`API_BASE` near the top of the script points at the Worker (`/api/health`, `/api/readings`, `/api/prices`). The Worker collects FoxESS and Amber data every five minutes.

## Known issues

- Sell prices only exist from when the updated Worker first ran (it backfills about 48 hours on its first run). Export before that is not valued.
- Amber reports feed-in `perKwh` as negative when you are paid; the dashboard flips the sign so sell rates display as earnings.
- The projection can still be inflated by forecast price spikes (Amber forecasts at the market price cap, about 2,550¢/kWh including GST, are real forecasts, not errors).
- Cost maths uses measured grid import/export kW sampled every five minutes, so it is an estimate, not an invoice figure.
- The projected earnings and cost use forecast prices capped at 100¢/kWh (`SPIKE_CAP`), which is still well above normal prices; if Amber forecasts a spike, most of the projection comes from it. The line under the tiles shows the figure if the spikes happen.
- The Worker stores the FoxESS history point and the live point as separate rows about a second apart, so each time appears twice in the database (the Recent readings table hides this).

## Release notes

### 2.1 (12 October 2026)

- **Sell prices**: the Worker now stores Amber buy (`general`) and sell (`feed-in`) prices and returns `channelType`; first run backfills about 48 hours. Fixed the sell rate showing the buy price, and export revenue being valued at the buy rate. Feed-in prices are flipped from Amber's negative convention.
- **Export earnings**: new tiles for earned so far, kWh exported, average sell rate and projected earnings at midnight; warning when the battery is under 50% and still exporting after 2:45pm.
- **Projection**: uses your usual import/export for each half-hour over the previous three days, with forecast prices capped at 100¢/kWh and the uncapped figure shown underneath.
- **History graphs**: split into three aligned graphs (battery, solar vs house usage, signed grid export/import) on a real time axis with gaps shown as breaks, a hover bubble across all graphs, and drawing that fits the card width at any window size.
- **Price chart**: capped axis with red bars above it, buy and sell bars side by side, negative dollars shown as -$.
- **Recent readings**: one row per half-hour mark.
- **Removed**: the Charge planning card.

## Editing

The file is minified in places. Make small targeted edits, then commit and push with GitHub Desktop; the site updates after deployment.
