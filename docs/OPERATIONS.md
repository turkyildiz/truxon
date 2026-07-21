# Operations reference — current as of 2026-07-21

The living "how it runs and how to fix it" doc. Supersedes MONDAY_RUNBOOK.md
(kept as history). Companion pieces: [RESTORE_DRILL.md](RESTORE_DRILL.md),
[TECHNICAL.md](TECHNICAL.md).

## Scheduled jobs (pg_cron, all times UTC)

| Job | When | What |
|---|---|---|
| trux-inbox poll | */2 min | forest@ mailbox → agent (propose-only) |
| dispatch-watch | */20 min | dispatch@ shadow observations |
| dispatch miner | 2h | files missing PODs/paperwork, fills customer blanks |
| qbo pull / pnl / customers | 30 min / nightly | QBO mirror sync |
| truxon-quote-mining | 2h at :40 | quote emails → sales pipeline |
| geocode / eld-sync / fmcsa-watch | frequent | enrichment + telematics + safety |
| metric snapshots | nightly | playbook series → metric_snapshots |
| sentinel scan | frequent | findings incl. ≥25% WoW trend breaks |
| eld daily rollup / IFTA attribution | 03:07 / 03:17 | GPS miles bank → state attribution |
| truxon-truck-features | Mon 03:27 | breakdown-risk feature bank |
| truxon-db-backup | 03:37 | 26 tables → private db-backups bucket (30d) |
| truxon-weekly-digest | Mon 12:00 | last week's flash → shadow feed |
| truxon-dunning-drafts | Mon 13:10 | overdue-customer reminder DRAFTS → shadow |

All edge-bound jobs go through `app_private.cron_edge_call()` carrying
`x-cron-key`. **If every edge cron starts failing at once, the CRON_SECRET
is the first suspect.**

## CRON_SECRET rotation

1. Generate a new secret; `supabase secrets set CRON_SECRET=…` (no redeploy
   needed — env is read per invocation).
2. Seed the DB-side copy via the watchdog's admin-JWT-gated
   `{set_cron_secret: …}` mode (calls service-only `set_cron_config()`).
3. Verify: any keyed cron call returns 200; anon call returns 401.
The secret is never in git. The NAS doc-rag worker needs it when NAS returns.

## Backups

Nightly dump to the private `db-backups` bucket + the (parked) NAS pipeline.
Restore procedure and the drill's lessons: [RESTORE_DRILL.md](RESTORE_DRILL.md).
First drill passed 2026-07-21. Re-drill quarterly.

## Forest exam harness

Repeatable regression pattern (first run R12 #1, rerun R4):
1. Reactivate `forest-exam@truxon.com` via service PATCH on profiles;
   password-login for a fresh token.
2. Questions JSON + runner ask prod `trux-agent` per question; grade against
   service-RPC ground truth.
3. Fix gaps at the source (tool catalog / scorecard), redeploy
   trux-agent+trux-inbox, re-ask the misses.
4. Deactivate the exam user.
Runner lives in the session scratchpad; the pattern is small enough to
recreate from this description.

## Mobile releases

`cd mobile && ./publish-release.sh "what changed"` → GitHub release; devices
self-update OTA (sha256-verified, https+GitHub-host allowlisted).
**Pending a release right now:** driver NPS prompt + "My week" card are in
the tree but not on devices until the next APK is published.

## When something breaks

- Watchdog (edge, cron-keyed) heals known failure modes and files incidents;
  RESPONDER_AUTOFIX stays **off** in production.
- Sentinel `/shadow` feed + daily brief carry findings; trend breaks land
  there too.
- Deploy paths: frontend auto via Vercel on push to main; DB via
  `supabase db push` (linked CLI); edge via `supabase functions deploy <fn>`.
  **Always read the pgTAP result BEFORE pushing** — on 2026-07-21 a masked
  FAIL let a broken scorecard reach prod for ~3 minutes.
