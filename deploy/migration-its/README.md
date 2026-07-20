# ITS Dispatch nightly delta capture

Logs into ITS Dispatch every night, reads the dispatch board, pulls every
load's full record, and **accumulates** them into a local staging file. It
**never writes to Truxon prod** — the cutover import is a single, reviewed step.

```
NAS cron (01:00 CST)
  → fetch-its.mjs  (Playwright, credential login to ITS)
      POST dispatchboard_list.php (open + closed) → editIds
      GET  edit_data.php?id=<editId>            → full load HTML
      parse (in-page DOMParser)                 → structured load
  → merge into its_loads_full.json  +  its_delta/YYYY-MM-DD.json snapshot
  ── nothing leaves for prod ──
At cutover (~Aug 1):
  → node import.mjs <admin> <pw>   (idempotent; skips load_numbers already in prod)
```

**Why nightly, not one-shot at cutover:** once a load is invoiced in ITS it
disappears from the dispatch board. Capturing every night grabs each load while
it is still visible, so nothing created-then-archived between the bulk import
and go-live is missed. See `ITS_EXTRACTION.md` for the reverse-engineered
endpoints and field map.

## One-time setup on the NAS

1. Node 20+ and Playwright's Chromium (image already pulled for the fuel job):
   ```bash
   cd deploy/migration-its && npm install && npx playwright install chromium
   ```
2. Create `deploy/migration-its/its.env` (chmod 600):
   ```
   ITS_ACCOUNT=IL76053
   ITS_USERNAME=<the ITS username>       # or ITS_EMAIL=<login email>
   ITS_PASSWORD=<the ITS password>
   ITS_LOOKBACK_DAYS=120
   # optional failure alerts through the watchdog:
   ALERT_WEBHOOK=https://okoeeyxxvzypjiumraxq.supabase.co/functions/v1/watchdog
   WATCHDOG_REPORT_KEY=<same as the watchdog report key>
   SUPABASE_ANON_KEY=<anon key, for the watchdog verify_jwt gate>
   ```
   Credentials are read from this file only; they are never logged.
3. Prove it end-to-end before scheduling:
   ```bash
   node fetch-its.mjs --selfcheck    # login + parse a few loads + assert invariants
   node fetch-its.mjs --once         # one real capture, snapshot only (no merge)
   ```
   `--selfcheck` exits non-zero (and alerts) if ITS changed its HTML.

## Cron — 01:00 America/Regina (Saskatchewan, UTC−6, no DST)

Matches the existing NAS backup/fuel schedule convention (memory: NAS TZ is
America/Regina). 01:00 CST → 07:00 UTC, fixed year-round.

```cron
CRON_TZ=America/Regina
0 1 * * *  cd /volume1/docker/truxon-its && /usr/bin/node fetch-its.mjs >> its.log 2>&1
# UTC-equivalent if the scheduler ignores CRON_TZ:
0 7 * * *  cd /volume1/docker/truxon-its && /usr/bin/node fetch-its.mjs >> its.log 2>&1
```

On the DXP8800 the crons run inside the busybox `crond` scheduler container
(host cron needs root, which isn't available) — add the line to that container's
crontab exactly like the backup/fuel jobs, using the Playwright-capable image.

## What lands where

- `its_loads_full.json` — the **accumulated** delta (deduped by editId, updated
  when a load's status/rate/stops change). This is what `import.mjs` reads.
- `its_delta/YYYY-MM-DD.json` — an immutable raw snapshot per run (audit trail;
  includes board counts + parse warnings).
- `its.log` — run log.

## Modes

| Command | Effect |
|---|---|
| `node fetch-its.mjs` | scheduled run: login → capture → snapshot → merge |
| `node fetch-its.mjs --once` | capture + snapshot, **no** merge (inspect first) |
| `node fetch-its.mjs --selfcheck` | login + parse + assert invariants, prints a sample |
| `node fetch-its.mjs --login` | manual persistent-profile login fallback (headed) |
| `node fetch-its.mjs --headed` | run with a visible browser (debugging) |

## Status

- **Extraction + parser:** reverse-engineered and **validated live** against real
  loads (1136 single-stop, 1162 multi-stop). Endpoints/field map in
  `ITS_EXTRACTION.md`.
- **This fetcher:** written; deploy on the NAS with `its.env`, run `--selfcheck`
  once, then schedule. Selectors/endpoints mirror the current ITS; `--selfcheck`
  is the tripwire if they change.
- **Cutover import (`import.mjs`):** already built and idempotent — unchanged.
