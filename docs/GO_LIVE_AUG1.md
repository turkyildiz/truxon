# Aug 1 cutover — audited status (2026-07-21)

Walked against live prod, not aspirations. The platform has been running in
production since ~Jul 16; "go-live" now means **cutting off ITS and running
the business solely here**.

## Verified live (receipts from the 2026-07-20/21 overnight runs)

- Web app on truxon.com (Vercel, CSP/HSTS headers), 609 pgTAP asserts green
- QBO mirror every 30 min; GL/balance mirrors feeding CFO reporting
- forest@ agent + dispatch@ shadow + 2h miner (owner-approved, audited)
- ELD sync + GPS miles bank + IFTA attribution (52 jurisdictions, filing
  view on the Fuel page)
- Nightly off-site backup, restore-drilled (26/26 tables)
- Security: all Ground-Truth report findings closed; CRON_SECRET
  architecture live; inactive-account lockout; money-path locks
- Collections workroom + dunning drafts, stress tests, keep-or-fire,
  exposure guard, load actuals, driver scorecards, weekly digest
- OTA self-update (sha256 + host allowlist) — devices update from releases

## Owner-owed before or at cutover

| Item | Why | Effort |
|---|---|---|
| Publish next APK (`cd mobile && ./publish-release.sh "NPS + my week"`) | Ships driver NPS prompt + My-week card | 5 min |
| ITS final delta import + stop paying ITS | The actual cutover | ~1h assisted (Cloudflare blocks unattended login) |
| M365 Application Access Policy (Exchange PowerShell, cmd in GO_LIVE.md §6) | Scopes the Graph app to its mailboxes | 10 min |
| DND alarm verification on both tablets (old runbook §B) | Confirm urgent pushes ring on locked tablets | 15 min |
| DriveHOS company key from Aida | Unblocks richer telematics (HOS, engine hrs) | ask Aida |
| NAS SSH access | Backup redundancy + doc-rag worker (needs CRON_SECRET) | when available |
| QBO push-mode flip | Truxon becomes books-of-record writer — decision, not code | decide |

## Day-of smoke (unchanged, 15 min)

Login → create/verify driver link → driver pin on Live fleet → status flow
to Delivered → Forest answers "list available trucks" → document upload
reaches the driver. Post-deploy script: `ADMIN_EMAIL=… ADMIN_PASSWORD=…
node scripts/post-deploy-smoke.mjs` (env-only credentials now).

## Not blocking cutover

Trend-break findings arm themselves as snapshot history accrues this week;
load-actuals variance turns real for post-Jul-19 deliveries; breakdown-risk
ML waits on ~2 months of banked features; driver NPS waits on responses.
