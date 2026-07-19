# Fuel integration (AtoB → Truxon)

Pulls the AtoB fuel-card transactions CSV twice a day and imports it into
Truxon's `fuel_transactions` table (per-truck fuel cost, weekly accounting,
IFTA by jurisdiction).

## How it works

```
NAS cron (03:00 & 16:00 local)
  → fetch-atob.mjs  (Playwright, persistent Auth0 session)
      drives the AtoB UI → Export Transactions → downloads CSV
  → POST the CSV to  fuel-import  edge function  (X-Fuel-Key)
      parses + upserts on AtoB's UUID (idempotent) → matches truck by unit#/VIN
```

Idempotent by design: the export uses a rolling `FUEL_LOOKBACK_DAYS` window
(default 35), and every row is keyed by AtoB's own UUID — so a *pending* charge
that later *settles* (gaining gallons and net-of-discount) updates its existing
row instead of duplicating. Re-running any time is safe.

## One-time setup on the NAS

1. Node 20+ and Playwright's Chromium:
   ```bash
   cd deploy/fuel && npm install && npx playwright install chromium
   ```
2. Create `deploy/fuel/fuel.env` (chmod 600):
   ```
   TRUXON_FUEL_IMPORT_URL=https://okoeeyxxvzypjiumraxq.supabase.co/functions/v1/fuel-import
   FUEL_IMPORT_KEY=<same value set as the fuel-import secret>
   FUEL_LOOKBACK_DAYS=35
   # optional failure alerts through the watchdog:
   ALERT_WEBHOOK=https://okoeeyxxvzypjiumraxq.supabase.co/functions/v1/watchdog
   WATCHDOG_REPORT_KEY=<same as the watchdog report key>
   ```
3. Set the edge-function secret (from the work machine):
   ```bash
   supabase secrets set FUEL_IMPORT_KEY=$(openssl rand -hex 24)
   supabase functions deploy fuel-import
   ```
4. **First login** (opens a real browser window — do this once, on the NAS
   desktop or over VNC):
   ```bash
   node fetch-atob.mjs --login
   ```
   Sign in to AtoB, then press Enter. The session is saved to the persistent
   profile and reused by every scheduled run; Auth0 refresh keeps it alive.
   When it eventually expires, a scheduled run emails an alert and you repeat
   this step.

## Cron (local time)

`0300` and `1600` local — set the crontab in the NAS's own timezone (confirm
with `timedatectl`):

```cron
0 3,16 * * *  cd /path/to/truxon/deploy/fuel && /usr/bin/node fetch-atob.mjs >> fuel.log 2>&1
```

## Manual import (no scheduler needed)

Any admin can import a CSV by hand — export from AtoB, then:
```bash
curl -X POST "$TRUXON_FUEL_IMPORT_URL" \
  -H 'Content-Type: text/csv' -H "X-Fuel-Key: $FUEL_IMPORT_KEY" \
  --data-binary @export.csv
```
Response: `{ parsed, inserted, updated, unmatched_trucks }`. `unmatched_trucks`
counts rows whose AtoB "Vehicle Name" didn't match a Truxon `trucks.unit_number`
(or VIN) — add/rename the truck and re-import to match them.

## Status

- **Ingestion (schema + importer + reporting):** built, verified end-to-end
  against a real 200-row AtoB export (parse, idempotent upsert, truck matching,
  IFTA aggregation). Ships with `supabase db push` + `functions deploy fuel-import`.
- **This fetcher:** written but **not yet run** — it needs deployment on the
  always-on NAS plus the one-time AtoB login. Deploy once NAS SSH access is
  available (see the parked NAS access note). The selectors are text-based and
  mirror the current AtoB UI; verify them on first run.
