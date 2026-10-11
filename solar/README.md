# Solar & Battery dashboard

Read-only dashboard served at https://geeking.commonsense.com.au/solar/. It is a single file (`index.html`, inline CSS and JS) that reads JSON from the Cloudflare Worker in [`../worker`](../worker/README.md); there is no build step.

## What it shows

- **Energy at a glance**: battery state of charge, stored energy, total solar, household load, battery charge/discharge, grid import and the current Amber import price.
- **Battery and solar history**: battery charge (%), solar power (kW) and grid import (kW) over 24 hours, 7 days or 30 days.
- **Electricity cost today**: Amber price bars for the Sydney day (history and forecast), estimated cost so far, projection to midnight and the current rate. Net cost is import cost minus export revenue.
- **Charge planning**: energy needed to reach a target charge, time at a given rate, and the lowest-price forecast windows. Estimate only; it never controls the inverter.

## Data source

`API_BASE` near the top of the script points at the Worker (`/api/health`, `/api/readings`, `/api/prices`). The Worker collects FoxESS and Amber data every five minutes.

## Known issues

- Sell (feed-in) price bars and the sell rate beside the current rate need the Worker to store Amber's `feed-in` channel. It currently stores only `general`; see the Worker README.
- Cost maths uses measured grid import/export kW sampled every five minutes, so it is an estimate, not an invoice figure.

## Editing

The file is minified in places. Make small targeted edits, then commit and push with GitHub Desktop; the site updates after deployment.
