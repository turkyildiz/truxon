# Toll integration (PrePass → Truxon)

Pulls toll transactions from the **PrePass Toll Transaction API** into Truxon's
`toll_transactions` table (per-truck toll cost, tolls by jurisdiction/agency,
and **violation** flags). Unlike the AtoB fuel fetcher, PrePass exposes a real
API, so this runs **fully serverless** — a Supabase edge function (`toll-sync`)
invoked by pg_cron. **No NAS required.**

## How it works

```
pg_cron (daily)
  → toll-sync edge function
      1. POST PrePass Token API (client id + secret) → bearer token
      2. GET /tolltransaction/v1/transactions (rolling postDate window, paged)
      3. import_toll_transactions RPC → upsert on tollId, match truck by vehicleNumber → unit_number
```

Idempotent: keyed on PrePass `tollId`, with a rolling `TOLL_LOOKBACK_DAYS`
window, so re-runs and corrections (a disputed toll updating) never duplicate.

## Setup

1. Get PrePass API credentials from the **developer portal** (developer.prepass.com):
   a client ID + secret (Token API) and your PrePass **account number(s)**.
   Confirm the exact **token URL** on the portal's Token API page — the function
   defaults to `https://api.prepass.com/token/v1/token`; override with
   `PREPASS_TOKEN_URL` if it differs.
2. Set the secrets (from the work machine):
   ```bash
   supabase secrets set \
     PREPASS_CLIENT_ID=... PREPASS_CLIENT_SECRET=... \
     PREPASS_ACCOUNT_NUMBERS=573890 \
     TOLL_SYNC_KEY=$(openssl rand -hex 24)
   # optional: PREPASS_TOKEN_URL=... TOLL_LOOKBACK_DAYS=14
   supabase functions deploy toll-sync
   ```
   Until these are set, `toll-sync` no-ops (`{skipped:'not configured'}`), so
   scheduling it early is harmless.
3. **Test it once** manually before scheduling:
   ```bash
   curl -X POST "https://okoeeyxxvzypjiumraxq.supabase.co/functions/v1/toll-sync" \
     -H "X-Toll-Key: <the TOLL_SYNC_KEY you set>" -H 'Content-Type: application/json' -d '{}'
   # → { ok, fetched, inserted, updated, unmatched_trucks, violations }
   ```

## Schedule (pg_cron)

The cron carries the secret `TOLL_SYNC_KEY`, so it is NOT committed to git —
create it once in the SQL editor after deploy. Daily at 10:00 UTC (≈04:00
Central America, UTC−6). Store the key in Vault so it isn't inlined:

```sql
-- one-time: stash the key in Vault
select vault.create_secret('<the TOLL_SYNC_KEY>', 'toll_sync_key');

select cron.schedule('truxon-toll-sync', '0 10 * * *', $$
  select net.http_post(
    url := 'https://okoeeyxxvzypjiumraxq.supabase.co/functions/v1/toll-sync',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'X-Toll-Key', (select decrypted_secret from vault.decrypted_secrets where name = 'toll_sync_key')
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 120000
  );
$$);
```

An admin can also trigger a sync manually anytime from an authenticated session
(the function accepts an admin JWT in place of the `X-Toll-Key`).

## Status

- **Ingestion (schema + importer + reporting):** built and unit-tested (dedup,
  truck match, violation counting, by-truck/by-agency reporting — 9 pgTAP
  assertions). Ships with `supabase db push`.
- **toll-sync:** written and typechecked; **not yet run end-to-end** — needs the
  PrePass credentials above. The token-URL default and response field names are
  best-effort from the portal; verify on first manual run.
