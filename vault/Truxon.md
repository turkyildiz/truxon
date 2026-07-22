---
title: Truxon
tags: [moc, product]
aliases: [Truxon TMS, Aida Logistics]
---

# 🚛 Truxon — the whole system, one note

Truxon is a **live production Transportation Management System (TMS)** for **Aida Logistics LLC**, a trucking company. It's built and owned solo by [[user-ilker|Ilker Turkyildiz]] — the entire platform (web, mobile, an AI C-suite, integrations) shipped in weeks. This note is the canonical overview; every section links to the note that goes deep. See also the vault [[Home]].

> **Go-live: Aug 1, 2026.** Until then it's not in real use — prod data is test data, so pushes are low-risk and Ilker ships freely. **On/after Aug 1, revert to careful, deliberate deploys.** ([[project-truxon]])

## The one-paragraph pitch
Truxon runs the whole business off one Supabase database: booking and dispatching loads, tracking trucks live, invoicing brokers and chasing the money, fuel and toll ingestion, maintenance, driver paperwork, IFTA — and on top of it all, **[[northstar-project|Forest]]**, an AI that answers the owner's C-suite questions from real data, watches the business 24/7 for problems, and files documents from email. It replaces a stack of SaaS tools (TMS + accounting mirror + factoring + comms) with one system the owner fully controls.

## Stack & deploy
| Layer | Tech |
|---|---|
| Database + backend | **Supabase** (Postgres + RLS + Edge Functions + Storage + cron). Prod ref `okoeeyxxvzypjiumraxq` (us-east-2) |
| Frontend | **React + Vite + TypeScript**, deployed on **Vercel** → **truxon.com**. `git push main` = prod deploy |
| Mobile | **Flutter** driver/companion app, OTA-updated from GitHub releases (`turkyildiz/truxon-releases`), manual fleet sideload |
| Repo | `~/src/truxon` — GitHub `turkyildiz/truxon` (private). Migrations forward-only; `supabase db push` applies to prod |
| Backups | Nightly pull to a **UGREEN NAS** (GPG-encrypted, 30-day) + Backblaze B2 offsite + a Supabase-side db-backup bucket |

Deploy discipline, DB gotchas, and the sentinel-splice pattern live in [[engineering-conventions]]. How Claude works on it (autonomy, push=prod, verification) is [[working-agreement]].

## Forest — the AI layer 🌲
The assistant is **Forest** (renamed from "Trux" in 2026-07; internal identifiers stay `trux_*`). Voice is **"Havoc"** (a licensed ElevenLabs library voice). Mailbox **forest@truxon.com**.
- **`trux-agent`** — the exec analyst: answers owner questions using a large catalog of pre-verified report RPCs (financials, ops, safety, playbook, forecasts) — see the catalog in `_shared/truxcore.ts`.
- **`trux-inbox`** / **`dispatch-watch`** — email doors: classify and file emailed documents under the right record, mine dispatch mail for missing PODs, fill customer blanks. All **RLS-scoped, propose-only, audited, reversible** ([[trux-dispatch-shadow]], [[wo-email-intake]], [[customer-enrichment]]).
- **`trux-sentinel`** — the 24/7 watchdog (below).
- Proactive co-pilot on mobile: ambient radio alerts, voice-first driver actions.

## Core modules
- **Loads & Dispatch** — booking, assignment, workflow-guarded status (`change_load_status`), live margin at booking, broker rate history, credit-exposure guard.
- **Accounting** — invoicing + emailing brokers, payments (check/ACH/**factoring**), receivables/aging/DSO, unbilled-load leak detection, **[[factoring-ar|factoring]]** reserves, a **[[qbo-integration|QuickBooks]]** mirror (optional, not a dependency), a true GL P&L mirror.
- **Maintenance** — PM programs, due/compliance engine, cost analytics, work-order intake from emailed shop sheets.
- **[[fuel-theft-detection|Fuel]]** — CSV ingestion, IFTA, theft detection (non-diesel, cash advances, tank overflow, miles-vs-fuel).
- **[[tolls-prepass|Tolls]]** — PrePass SFTP → NAS importer → `toll_transactions`.
- **Track & Map** — live fleet map, **[[geocoding]]** of stops, truck-safe **Valhalla** routing (on the NAS), weather + parking layers.
- **Drive** — a Dropbox-like document store with folders, sharing, and **doc search** (embeddings via the [[nas-local-llm|NAS local LLM]]).
- **Radio** — one-app PTT over Supabase Realtime, always-on RX in a foreground service ([[one-app-radio]]).
- **Mobile companion** — role-adaptive shell (dispatch/accounting/admin/driver), POD scanner, DVIR pre-trip, NPS, GPS tracking. Session at rest lives in the Android **keystore**.

## Northstar — the predictive push 📈
The drive to make Truxon **Level 5 (predictive)**: cash-flow & slow-pay forecasts, load margin at booking, weekly revenue/utilization outlook, breakdown-risk groundwork — plus a **1000-metric C-suite playbook** ([[csuite-playbook]]) that's now at **171/1000 live** and climbing. Full run-by-run log in [[northstar-project]]. Data feeds: **[[eld-drivehos|ELD/DriveHOS]]** telematics, geocoding, FMCSA safety, PrePass tolls, QBO GL.

## Sentinel — the proactive brain
`sentinel_scan()` runs ~40 checks and files self-resolving findings into the in-app feed + daily brief: unbilled-load leaks, missing PODs, detention-to-bill, slow-pay & broker credit exposure, **broken promise-to-pay**, **customer churn-risk**, data-integrity gaps, maintenance-due, safety/CSA, fuel theft, and the security tripwires below. Each finding auto-resolves when the condition clears. Pattern for adding checks: [[engineering-conventions]].

## Security posture 🛡️
Defense-in-depth, all live and owner-visible on the `/security` console ([[security-posture]]):
- **Cron-secret** auth on every privileged door (no anon-JWT authorization).
- **Honeypots** (decoy `api_keys`/`bank_accounts`) + **honeytokens** — replay trips a critical alarm.
- **Ransomware guards** — block DROP/TRUNCATE (DDL) *and* bulk DELETE / alarm on bulk UPDATE (DML) on crown-jewel tables.
- **Tamper-evident audit log** (hash-chained, append-only), **posture-drift** detection, **break-glass lockdown**.
- **MFA/TOTP** self-service for every office user (opt-in today; enforcement later).
- Honest residual gaps: OTA manifest signing (M-4) and NAS hardening (B2 Object Lock + secrets) — both owner-gated.

## Integrations
[[qbo-integration|QuickBooks Online]] · [[eld-drivehos|ELD DriveHOS]] · [[tolls-prepass|PrePass tolls]] · [[factoring-ar|Denim factoring]] · Microsoft 365 mail (Graph) · [[nas-access|the NAS]] (backups, Valhalla, local LLM, fuel/toll jobs) · [[nas-local-llm|self-hosted qwen2.5]].

## Where to go next
- **How we work / rules:** [[working-agreement]] · [[engineering-conventions]] · [[finish-before-next]] · [[week-standard]]
- **The build history & metrics:** [[northstar-project]] · [[reports-index]]
- **Everything else:** [[Home]] · [[Memory/MEMORY|Memory index]]
