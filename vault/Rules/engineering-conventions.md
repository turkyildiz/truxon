---
title: Engineering Conventions
tags: [rules, engineering]
---

# 🛠️ Engineering Conventions & Gotchas

The repeatable patterns and the traps that have bitten us. Follow these to keep changes safe. Related: [[security-posture]], [[northstar-project]], [[week-standard]].

## Repo & deploy
- Repo: `~/src/truxon`. Frontend (React+Vite) deploys via Vercel on push to `main`. Supabase prod ref `okoeeyxxvzypjiumraxq`.
- **Migrations** → `supabase db push`. **Edge functions** → `supabase functions deploy <name>`. Config-only/comment changes need no redeploy.
- Regenerate types after new RPCs: `supabase gen types typescript --linked > frontend/src/database.types.ts`.
- Mobile APK: `mobile/build-apk.sh release` (bundles the `--dart-define` Supabase/Valhalla values). Fleet rollout is **manual sideload** — owner-gated.

## The Sentinel splice pattern (adding a `sentinel_scan` check)
`public.sentinel_scan()` is redefined in full by each migration (functions are `create or replace`). To add a check:
1. Extract the **latest** full definition (from the most recent migration that redefines it) with `awk '/^create or replace function public.sentinel_scan/{f=1} f{print} f&&/^\$\$;$/{exit}'`.
2. Splice a new `insert into _findings … ;` block **before** the `-- ===== upsert + auto-resolve =====` marker.
3. Ship the whole redefined function in a new migration. Never hand-edit an applied migration.
- Findings auto-resolve: any `dedup_key` not re-emitted this scan is set `resolved`. Test the full **quiet → fire → resolve** lifecycle.

## Database gotchas (each cost real time)
- **pgcrypto must be `extensions.`-qualified in migration DDL** (`extensions.digest/crypt/gen_salt`) — `supabase db push` runs with a restricted `search_path` and fails where local `psql` succeeds. `gen_random_uuid()` is core (safe).
- **`trux_insights.category`** CHECK = `money | cash | ops | compliance | maintenance | data`. There is **no `revenue`** — churn/revenue findings use `cash`.
- **`trux_insights.entity_type` is NOT NULL.** Aggregate findings (no single row) use a constant like `'load'`/`'invoice'`/`'security'` with `entity_id = null`.
- **`stable`/`immutable` functions can't `CREATE TABLE AS`** (or temp tables). Use repeated CTE selects instead.
- **Local grants ≠ prod grants.** A fresh `db reset` doesn't reproduce prod's default table grants (e.g. `authenticated` SELECT on `profiles`). RLS pgTAP tests must `grant … to authenticated` **inside** their rolled-back transaction.
- **`eld_location_history.id` is a `uuid` with no default** — supply `gen_random_uuid()` in test inserts.
- **Loads are workflow-guarded**: can't bulk-`UPDATE` status (use `change_load_status()`), and **billed loads are locked** (void the invoice first). Tests that need to mutate should use `completed` loads / `DELETE`.
- **Money-path & ransomware guards**: bulk `DELETE` >100 rows on crown-jewel tables is BLOCKED (`app.allow_bulk_dml='on'` to bypass); DROP/TRUNCATE on public tables is BLOCKED (`app.allow_drops='on'`). A migration that legitimately drops a public table must set the flag first.

## Testing & verification
- pgTAP lives in `supabase/tests/NN_*.sql`; run with `supabase test db`. Add one test per new RPC/sentinel check.
- Valid category/enum/gate assertions + the fire→resolve lifecycle are the standard shape.
- Frontend: `npm run build` (tsc + vite). Mobile: `flutter analyze` + `flutter test`. Deno edge: `deno check`. (truxcore.ts carries ~pre-existing RPC-typing noise — compare error counts vs a `git stash` baseline, don't chase it.)

## Forest exam harness (verify the agent after a catalog change)
Temp admin via GoTrue admin API (service key from `supabase projects api-keys`) → password-grant login → POST each question to `trux-agent` → grade against report RPCs → **deactivate the temp user after**. The agent catalog is one long string in `supabase/functions/_shared/truxcore.ts` (used by `trux-agent` + `trux-inbox`); splice new tool blurbs before the `budget list note`.

## Tablet UI
Headless Pixel-Tablet AVD (`truxtab`) on the dev box — see [[android-emulator]]. Verify **all** tablet UI visually before publishing. (Web-only changes don't run on the Flutter app; a "tablet pass" doesn't apply to them.)
