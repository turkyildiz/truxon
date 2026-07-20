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
- ✅ **Verified backups** — deployed on the NAS (2026-07-19). A `truxon-scheduler`
      Docker container (busybox crond via the docker socket; host cron needs root
      we don't have) runs the hardened `deploy/backup/*` scripts: nightly encrypted
      backup 02:00 CST + weekly restore test Sun 04:00 CST. Verified end-to-end —
      full backup (662K DB dump + 872M storage archive, 2,463 objects across
      documents/personal/team) AND a restore test that PASSED (5 profiles / 984
      loads / 203 customers / 2,457 docs into a throwaway Postgres). Watchdog
      `backup_fresh` heartbeat now green (WATCHDOG_REPORT_KEY rotated + anon bearer).
      Fixed two real script bugs in the process (storage URL-encode; heartbeat auth
      header) — see below. Old broken-storage container retired.
- ✅ **Ransomware-resistant off-site copy** (2026-07-19). Nightly backup now also
      uploads both encrypted files to a Backblaze B2 bucket (`truxon-backups`) with
      **Object Lock in COMPLIANCE mode** — a per-object retain-until date that
      NOTHING can delete before it expires: proven by test (the write key, which
      holds deleteFiles + bypassGovernance, got AccessDenied deleting a locked
      object). This copy survives full NAS root compromise, a Supabase compromise,
      fire, or theft — the real ransomware defense. Scoped append-style key on the
      NAS (`b2.env`, chmod 600). 3-2-1-1-0 now complete: Supabase + local NAS +
      immutable off-site, restore-tested. (On-box btrfs immutable snapshots are
      staged in `deploy/backup/immutable/` but not deployed — capped value given
      the NAS login is in the docker group, so the off-site WORM copy is the
      backstop instead.)
- ⬜ **Outbound email deliverability** — invoices + Trux replies send from the
      domain; verify SPF/DKIM/DMARC and send a test to an external inbox so they
      don't spam-file.
- ⬜ **Sentinel proactive push (#27)** — schedule + daily brief + push + in-app feed (below).
- 🔶 **Fuel & tolls live feeds** — **fuel is LIVE (2026-07-19)**: the AtoB
      Playwright fetcher runs on the NAS via `truxon-scheduler` cron at
      03:00/16:00 CST (UTC-6). Verified end-to-end through the cron path: 209-row
      CSV downloaded headless, idempotent import (2nd run: 208 updated / 0
      inserted). Session lives in `/volume1/docker/truxon-fuel/.atob-profile`;
      when it eventually expires the run alerts through the watchdog and the
      login is redone (headed browser on the dev box → tar profile to NAS).
      **19 unmatched_trucks** rows need unit-name reconciliation in Truxon.
      Tolls (PrePass) still pending the client-secret call.
- ⬜ **Seed data so modules aren't empty** — PM history + odometers (maintenance
      board / CPM) and monthly budgets (budget-variance).
- ⬜ **Company/invoice details** — logo, address, invoice numbering, payment terms
      correct before the first real invoice reaches a broker.
- ✅ **Accounting module (2026-07-19)** — Truxon as the complete money system, QBO
      now optional: payments ledger (partials, check/ACH/factoring, auto-paid at
      zero balance), invoice emailing from trux@ (invoice-send fn), DSO/aging/
      unbilled-leak/revenue/margin reports (acct_* RPCs, admin), Accounting page
      with paid/unpaid/past-due toggles + charts. Follow-up: verify a real
      invoice email lands (Graph Mail.Send is proven by watchdog, but eyeball
      the first broker send).
- ✅ **QuickBooks integration LIVE (2026-07-19)** — transition mode: QBO stays the
      books of record; Truxon mirrors it every 30 min (cron `truxon-qbo-pull`).
      First backfill: **812 invoices + 93 customers** from Aida Logistics' QBO.
      Payments in QBO flip Truxon invoices to paid → AR aging/Sentinel run on
      real cash. Intuit production app "Truxon" (workspace Truxon, compliance
      questionnaire passed same-day); redirect URI = the qbo-sync fn URL, set on
      the Settings→Redirect URIs tab. Push mode (Truxon-first invoicing) ships
      disabled behind QBO_PUSH_ENABLED — flip when trusted. Follow-ups: sandbox
      connect/disconnect test + intuit_tid capture (answered "not yet" on the
      questionnaire), success-page renders as raw HTML on some browsers
      (cosmetic), customer-dedup pass (93 QBO-created vs existing 203 by name).
- ✅ **API-key rotation fallout** — after the 2026-07-19 key rotation the raw
      service key's role claim no longer reports `service_role`, breaking every
      RPC gated on it. Swept all 14 such functions (fuel/toll importers, sentinel,
      maintenance, work-order draft) to `auth.uid() is null`; trux-sentinel also
      mints an admin session. Fixed & deployed.

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
