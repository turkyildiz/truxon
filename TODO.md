# Truxon — TODO

_Last updated: 2026-07-19_

## Pre-launch checklist (go-live Aug 1, 2026)

Ordered by risk. ✅ confirmed · ⬜ open (in our hands) · 🔶 needs Ilker / external.

- ✅ **Watchdog monitoring** — runs every 5 min in prod (cron `truxon-watchdog`).
- 🔶 **Real data migration from ITS Dispatch** — toolchain exists
      (`deploy/migration-its/import.mjs` + backfill_*.mjs + upload_docs.mjs). Prod
      still holds TEST data — needs the ITS export and a run against prod, then a
      row-count sanity check. Biggest silent risk.
- 🔶 **Staff accounts + roles** — create each user with the correct role; drivers
      also need the mobile app installed (blocked on the keystore below).
- 🔶 **Verified backups** — `deploy/backup/{backup.sh,restore_test.sh,storage_backup.py}`
      exist but deployment is parked on NAS access. Need one nightly backup + a
      real restore test before launch.
- ⬜ **Outbound email deliverability** — invoices + Trux replies send from the
      domain; verify SPF/DKIM/DMARC and send a test to an external inbox so they
      don't spam-file.
- ⬜ **Sentinel proactive push (#27)** — schedule + daily brief + push + in-app feed (below).
- 🔶 **Fuel & tolls live feeds** — fuel is manual CSV, tolls not flowing. Decide:
      automate (AtoB fetcher / PrePass) before launch, or start manual.
- ⬜ **Seed data so modules aren't empty** — PM history + odometers (maintenance
      board / CPM) and monthly budgets (budget-variance).
- ⬜ **Company/invoice details** — logo, address, invoice numbering, payment terms
      correct before the first real invoice reaches a broker.

## Now / next

- [ ] **Sentinel proactive wiring** ("comes to you" layer). The engine
      (`sentinel_scan`) and every check — money, cash, ops, compliance, safety,
      and now **maintenance** (overdue PM, repeat-breakdown units, stale work
      orders) — are live in prod. What's missing is the schedule that runs it
      and pushes you:
  - [ ] Schedule `sentinel_scan()` on a timer (pg_cron → edge fn, like
        `trux-inbox`), e.g. hourly + a morning run.
  - [ ] **Daily brief**: one push/email each morning summarizing open insights.
  - [ ] **Push for urgent**: fire a notification immediately on any new
        `critical` insight (reuse the `notify` function).
  - [ ] **In-app insights feed**: surface `trux_insights` (open/acknowledge) on
        the dashboard so items don't only live in the DB.

## Known gaps / follow-ups (from the maintenance + work-order work)

- [ ] **Scanned-PDF work orders**: the email/`extract-pdf` path reads text PDFs
      and photos, but a scanned PDF with no text layer isn't rasterized
      server-side (the reply asks the sender to send a photo instead). Add a
      server-side PDF→image render, or accept the photo-only fallback.
- [ ] **Attach the emailed sheet** to the drafted maintenance record's
      `documents` (today the original stays in the trux@ mailbox only).

## Parked — blocked on external access

- [ ] **NAS / backup sync** + `WATCHDOG_REPORT_KEY` heartbeat — blocked on UGOS
      access to `aida-nas`. (See memory: NAS access.)
- [ ] **AtoB fuel fetcher** (Playwright) deploy + cron on the NAS
      (0300 / 1600 Central America) — blocked on NAS SSH.
- [ ] **PrePass tolls**: set `PREPASS_CLIENT_ID/SECRET/ACCOUNT_NUMBERS` (573890)
      + `TOLL_SYNC_KEY`, then the Vault-based `toll-sync` cron — blocked on the
      PrePass call for the client secret.
- [ ] **Mobile keystore + republish** (steps in `RELEASES.md`).

## Roadmap — bigger bets

- [ ] **Instrumentation toward the 1,000-metric Owner's Playbook** (now 75 live).
      Highest leverage next: detention & accessorials (COO/CFO revenue leak),
      driver lifecycle (~136 CHRO metrics: turnover, cost-per-hire, tenure),
      then external feeds (ELD/telematics, FMCSA SMS, DAT rates, insurance).
- [ ] **Product track** (turn the Aida tool into a sellable product): multi-tenancy
      (`company_id` + tenant RLS), onboarding, support. Validate first with 2–3
      paying design-partner carriers on single-tenant instances before building
      the multi-tenant lift.
