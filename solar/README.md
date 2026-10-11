# Solar & Battery dashboard

Read-only dashboard served at https://geeking.commonsense.com.au/solar/. It is a single file (`index.html`, inline CSS and JS) that reads JSON from the Cloudflare Worker in [`../worker`](../worker/README.md); there is no build step.

## What it shows

- **Energy at a glance**: battery state of charge, stored energy, total solar, household load, battery charge/discharge, grid import and the current Amber import price.
- **Battery and solar history**: three aligned graphs over 24 hours, 7 days or 30 days. Battery charge (%) with a dashed 50% line; solar power against household usage (kW); and grid flow as one signed graph with export above the zero line (purple) and import below it (orange). The time axis is real clock time (Sydney), and a gap of more than 30 minutes in collection shows as a break in the lines. Hovering (or touching) any graph shows one bubble with the time, battery %, solar, house usage, grid export and grid import at that point.
- **Electricity cost today**: Amber buy and sell price bars for the Sydney day (history and forecast), estimated cost so far, projection to midnight and the current rate. Net cost is import cost minus export revenue. The chart axis is capped so normal prices stay readable; bars above the cap are red and the peak is noted on the chart. The projection uses your average import/export for each half-hour over the previous three days.
- **Export earnings today**: money earned so far from power sent to the grid (each interval's export kWh x its Amber sell price), kWh exported, average sell rate and projected earnings at midnight. A red warning appears when, after 2:45pm Sydney time, the battery is below 50% and still exporting (using the latest reading, if under 15 minutes old). Thresholds are in `renderDailyCost`.
- **Charge planning**: energy needed to reach a target charge, time at a given rate, and the lowest-price forecast windows. Estimate only; it never controls the inverter.

## Data source

`API_BASE` near the top of the script points at the Worker (`/api/health`, `/api/readings`, `/api/prices`). The Worker collects FoxESS and Amber data every five minutes.

## Known issues

- Sell prices only exist from when the updated Worker first ran (it backfills about 48 hours on its first run). Export before that is not valued.
- Amber reports feed-in `perKwh` as negative when you are paid; the dashboard flips the sign so sell rates display as earnings.
- The projection can still be inflated by forecast price spikes (Amber forecasts at the market price cap, about 2,550¢/kWh including GST, are real forecasts, not errors).
- Cost maths uses measured grid import/export kW sampled every five minutes, so it is an estimate, not an invoice figure.

## Editing

The file is minified in places. Make small targeted edits, then commit and push with GitHub Desktop; the site updates after deployment.
