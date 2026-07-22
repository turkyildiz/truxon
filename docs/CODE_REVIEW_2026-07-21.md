# Truxon TMS — Full Code Review (byte-level, 6-surface)

**Commit reviewed:** `23f6ec2` (working tree, incl. uncommitted changes) · **Date:** 2026-07-21
**Method:** Six independent deep-review passes — edge functions, SQL migrations, frontend, mobile, deploy/ops, and a cross-cutting money-path correctness hunt. Every finding was traced to the *latest* on-disk definition (functions are redefined via `create or replace`); line numbers were verified by reading the files. Static review, not a live pentest.

> **Headline for the team:** The prior Word security report (written against `c9260f9`) is **substantially remediated** in current `main`. The entire CRITICAL "cron = public anon JWT" family and the invoice/void/accessorial money bugs (B-01/02/03) are **fixed and verified** — see the RESOLVED table at the bottom. **Do not re-fix those.** There are **zero open CRITICAL or HIGH security holes.** The one item that is actively costing money is a *new* correctness bug the fixes left behind (H-1), and it's a small change.

---

## Priority queue (fix in this order)

| ID | Sev | One-line | Surface |
|----|-----|----------|---------|
| **H-1** | HIGH | Approved detention on an already-billed load is stranded — never collected (live revenue leak) | SQL money-path |
| **H-2** | HIGH* | Self-heal responder AUTOFIX mode: anon-reachable trigger + prompt-injection → autonomous `git push` to prod | deploy |
| **M-1** | MED | "Generate Invoice" preview total omits approved accessorials (server bills more than UI shows) | frontend + SQL |
| **M-2** | MED | Sign-out queue wipe races the tracking isolate's `onDestroy` → prev driver's GPS flushes under next driver's JWT | mobile |
| **M-3** | MED | Refresh token stored in plaintext SharedPreferences (access token is hardened, refresh isn't) | mobile |
| **M-4** | MED | OTA manifest unsigned — a compromised GitHub release defeats both host-allowlist and SHA-256 | mobile |
| **M-5** | MED | PrePass SFTP pull has no host-key verification (MITM → forged toll CSVs into prod financials) | deploy |
| **M-6** | MED | Admin/prod passwords passed on `argv` in 4 scripts (visible in `ps` / shell history) | deploy |
| **M-7** | MED | Runtime `pip`/`apt` installs unpinned, run every job (supply-chain + availability) | deploy |

\* H-2 is HIGH only when `RESPONDER_AUTOFIX=1`. Default posture is read-only and safe; treat "keep AUTOFIX off in prod" as a hard gate.

LOW / informational items (18) are grouped by surface at the end.

---

## HIGH

### H-1 — Approved detention on an already-billed load is stranded and never collected  *(CONFIRMED)*
**Where:** interaction of
- `detention_events()` — `supabase/migrations/20260720370001_sentinel_detention.sql:22-56` (selects loads with no `status`/`invoice_id` filter)
- `propose_detention_accessorials()` — `20260720790001_detention_evidence.sql:12`
- `decide_accessorial()` — `20260720530001_detention_billing.sql:58` (no load-status guard)
- `create_invoice()` — `20260720640001_security_p0.sql:120,159-172` (only folds accessorials for `completed`/un-invoiced loads)

**The bug:** Detention is detected from ELD/geocode data that usually lands *after* a load is quick-billed (loads bill within a day or two; the propose cron runs a 45-day window daily at 06:51). Sequence: (1) propose inserts a `proposed` accessorial on a load already `billed` with `invoice_id` set — nothing stops it; (2) office approves → `decide_accessorial` flips to `approved` with no billable-state check; (3) `create_invoice` is the *only* path that turns an approved accessorial into money, and it refuses any load that isn't `completed`/un-invoiced. The approved charge is now unreachable.

**Concrete:** Load delivered Mon, invoiced Tue. Wed the rollup lands; the cron proposes a $375 detention charge on the now-billed load. Owner approves Thu. Result: **$375 approved, uncollectable** unless someone manually voids the invoice and re-bills.

**Impact:** Silent, recurring detention leak — the exact revenue the feature exists to capture ($150–$600/stop). Note this is *not* B-01 (void→reopen, which is fixed); it's the more common "proof arrives after billing" path.

**Fix (do (a)+(b)):** (a) filter `propose_detention_accessorials` to loads still `completed` and `invoice_id is null`; (b) have `decide_accessorial` park/reject approval on an already-billed load and surface a "void & re-bill to collect" (or supplemental-invoice) action. Add a pgTAP case: propose→bill→approve must remain collectable.

### H-2 — Self-heal responder AUTOFIX: attacker-influenceable trigger + prompt injection → autonomous push to prod  *(conditional on AUTOFIX=1)*
**Where:** `deploy/watchdog/responder.mjs:87, 94-105, 128-136`

**The bug:** Default posture is well-built — read-only tool allowlist (`:130`), cooldown + fail-age gates, no privileged creds. The risk is entirely the opt-in `RESPONDER_AUTOFIX=1` path (`:128-129`) which adds `--dangerously-skip-permissions` and grants "code fixes, edge redeploys, git commit+push" (`:96-97`). Two sharp properties: (1) the trigger — watchdog checks red >15 min — is reachable with the **public anon key** per the file's own header (`:4-6`), so a sustained induced failure can *summon* the agent; (2) the prompt is built from `wd.recent_failures` (`:87`) — inbox/email-processing failure text that inbound mail can influence — injected verbatim into a session that, when armed, can `git push` to `main` (which deploys prod).

**Impact:** If AUTOFIX is ever enabled, an attacker who keeps an anon-reachable check red and seeds text into a logged failure can steer an autonomous, permission-skipping agent that pushes to production. Default mode: worst case is a misleading diagnosis email.

**Fix:** Keep AUTOFIX off in prod (hard gate). If it must exist: fence `recent_failures` as untrusted (don't interpolate verbatim), require a second non-anon signal to arm, drop `--dangerously-skip-permissions` for an allowlist that excludes `git push`/`functions deploy`, and require human approval before any push.

---

## MEDIUM

### M-1 — Invoice-creation preview omits approved accessorials  *(CONFIRMED by 2 passes)*
**Where:** `frontend/src/pages/Invoices.tsx:245` (preview `total`, shown at `:433`) vs server `create_invoice` `20260720640001_security_p0.sql:159-164`.
The preview sums only `l.rate`; the server adds every `approved` accessorial. Two loads $1,900+$1,600 with a $375 approved detention → preview says **$3,500**, the invoice created and emailed is **$3,875**. No money lost (server is right), but the office confirms a number lower than what the broker receives — a WYSIWYG break that invites disputes. **Fix:** pull approved accessorials for the selected loads (there's already `listAccessorials`) into the preview subtotal with a line-item breakdown, or fetch the server-computed total pre-commit.

### M-2 — Sign-out queue wipe races the tracking isolate's `onDestroy`  *(shared-tablet P0 class)*
**Where:** `mobile/lib/services/api.dart:323-334` vs `mobile/lib/services/tracking_service.dart:129-132`.
`signOut()` stops the service then `prefs.remove(kGpsQueue)`. But stopping triggers `onDestroy` **in the service isolate**, which async-calls `_persistQueue()` — `stopService()` resolving doesn't guarantee that write finished. If it lands after the remove, the previous driver's queued GPS fixes survive and flush on the next login under the **new JWT**. Timing-dependent → intermittent, silent GPS mis-attribution. **Fix:** clear queues only after the service is confirmed stopped (poll `isRunningService`), or set a sign-out flag that makes `onDestroy` skip persisting, or re-clear after a settle.

### M-3 — Refresh token in plaintext SharedPreferences
**Where:** `mobile/lib/services/auth_refresher.dart:149-153` (+ default `Supabase.initialize`, `main.dart:25`).
`session_store.dart` deliberately keeps the *access* token in Keystore ("a bearer token shouldn't sit in plaintext XML"), but `mergeSession` (`:66`) carries the longer-lived **refresh** token into a plaintext prefs blob. On a shared cab tablet, root/ADB/physical extraction yields off-device session impersonation — and the posture is inconsistent (weaker token hardened, stronger one not). Mitigated by `allowBackup=false` + FDE. **Fix:** give `Supabase.initialize` a `flutter_secure_storage`-backed `LocalStorage` so the whole session blob lives in Keystore.

### M-4 — OTA manifest unsigned
**Where:** `mobile/lib/services/update_service.dart:38-50, 55-76, 191-200`.
Host allowlist (HTTPS + github hosts) and SHA-256 are both correctly enforced (missing hash → `unverifiable`, refuses). But `sha256` and `apkUrl` come from the *same* `latest.json` with no out-of-band signature, so anyone with GitHub-release write access can point the fleet at a malicious APK *and* supply a matching hash — full RCE into every tablet, gated only on the release repo. (Code honestly documents this at `:41-43`.) **Fix:** sign `latest.json`/the digest with an offline key; verify with a public key baked into the app before honoring the manifest.

### M-5 — SFTP pull with no host-key verification
**Where:** `deploy/tolls/fetch-tolls.py:98-99`. Raw `paramiko.Transport` never checks the server host key — encrypted but unauthenticated endpoint. MITM between NAS and PrePass can harvest the SFTP password and feed forged CSVs straight into `toll-sync` → `toll_transactions`/financials. **Fix:** pin the host key (known-hosts / `SSHClient` + `RejectPolicy`), fail closed on mismatch.

### M-6 — Admin/prod passwords on `argv`
**Where:** `deploy/migration-its/upload_docs.mjs:2,14`, `deploy/stress/stress.mjs:7,15` (runs against **LIVE**), `deploy/migration-its/backfill_stops.mjs:2,11`, `backfill_extras.mjs:3,13`. Passwords land in `~/.zsh_history` and `ps -ef`. Pure house-pattern gap — siblings `import.mjs:2-3` and `post-deploy-smoke.mjs:6-8` already read `ADMIN_EMAIL`/`ADMIN_PASSWORD` from env *and comment on why*. **Fix:** switch the four to env.

### M-7 — Unpinned runtime installs
**Where:** `deploy/tolls/run-tolls.sh:8` (`pip install -q paramiko` every run — and paramiko handles the M-5 secret), `deploy/vision-enrich/run-vision.sh:11` + `vision-loop.sh:8` (`apt-get install -y poppler-utils` every run). Latest-version fetch+execute with no pin/hash inside a container that processes prod data → supply-chain + silent availability risk. **Fix:** bake deps into a pinned image (`truxon-rag-node` already shows the pattern) or pin exact versions with hashes.

---

## LOW / informational (grouped)

**SQL migrations**
- **LOW** `handle_new_user()` default role is `dispatcher`, not least-privilege `driver` — `20260719120002_signup_role_hardening.sql:17-20`. Only latent because signup is disabled. Default the `else` to `driver`.
- **LOW** `trux_query()` (ad-hoc read-only SQL) granted to *all* authenticated incl. drivers — `20260718233002_trux_query_readonly.sql`. Bounded (INVOKER + read-only + RLS) but drivers get a schema-enumeration surface. Gate to office roles.
- **LOW** `protect_last_admin` trigger covers UPDATE only, not DELETE — `20260720640001_security_p0.sql:72-74`. Add a `before delete` branch reusing the count check.

**Edge functions**
- **LOW** Sender/admin resolution scans only first `listUsers` page (`trux-inbox:246` perPage 200, `trux-sentinel:24`, `admin-users:32` 1000). Fails *safe* (rejects legit sender / sentinel no-runs) but silently breaks past the cap. Paginate to exhaustion or look up by email/id.
- **LOW** Shared-secret compares not constant-time (`fuel-import:108`, `toll-sync:93`, `notify:34,41-42`, `watchdog:404,418`) — inconsistent with the hardened `requireCron`. Route through one constant-time helper.
- **LOW** Emailed-attachment filing runs under the **service role** (RLS-bypassing) with the doc's own text choosing entity/values (`trux-inbox:442-457`, `dispatch-watch:70-208`). Bounded (verified active staff sender, blanks-only, audited, reversible). Run `matchEntity`/`fileDocument` under the acting user's session; scope only `storage.upload` to service role.
- **LOW** `quote-request` per-IP rate limit is in-memory/per-isolate & IP-spoofable (`quote-request:9,23-25`). Move the cooldown to a DB RPC like `extract-pdf` uses.
- **INFO** Stale `config.toml` comments say "anon bearer" where code enforces `CRON_SECRET` (stronger than documented); dead `auth` vars in `qbo-sync:412,424,442,461`. Correct comments + delete dead code so nobody "fixes" it backward.

**Frontend**
- **LOW** Equipment search bypasses `sanitizeSearchTerm` (`data.ts:250`) — not injectable (bound `.ilike` value) but `%`/`_` stay live wildcards. Route through the sanitizer for consistency.
- **INFO** Session tokens in `localStorage` (supabase-js default, `supabase.ts:11`) — acceptable given the strong CSP (`script-src 'self'`); revisit only under a BFF/httpOnly model.

**Mobile**
- **LOW** `unregisterPushToken` exists but is never called on sign-out (`api.dart:282-287`) — departing driver keeps getting DND-bypass alarms until next login. Call it in `signOut()`.
- **LOW** `diag_log` and radio username (driver full name) survive sign-out (`diag.dart`, `home_shell.dart:124`). Add to the sign-out wipe.
- **LOW** Release keystore password in plaintext `mobile/android/key.properties` — **but verified gitignored & uncommitted** (standard Flutter pattern). Move to env/keychain, keep the `.jks` backed up offline; reconcile the `storeFile` path drift vs `setup-release-key.sh`.

**Deploy/ops**
- **LOW** `scripts/go-live.sh:20-23` `source`s a user-supplied env file (evaluates `$()`/backticks); sibling `go-live-from-work-machine.sh:30-44` already has a hardened literal parser — reuse it.
- **LOW** `deploy/llm-proxy/proxy.mjs:16` non-constant-time bearer compare on a Funnel-exposed proxy. Use `crypto.timingSafeEqual`.
- **LOW** Predictable `/tmp/*.lock` paths on the multi-tenant NAS (`run-vision*.sh`, `run-tolls.sh`, `doc-rag/run-index.sh`) — local DoS/symlink. Move locks under a root-owned mode-700 dir.

---

## Verified RESOLVED — prior security-report items now fixed (do not re-fix)

| Prior ID | Concern | Fixing migration / file |
|----------|---------|-------------------------|
| **S-01** | Cron authenticated by public anon JWT (CRITICAL family) | `20260720660001_cron_secret.sql` — all privileged jobs re-scheduled via `cron_edge_call` + `x-cron-key`/`CRON_SECRET`; edge fns use `requireCron` (constant-time, fail-closed) |
| — | Anon fail-open on money mutators (`NULL not in(...)`) | `20260716250001_rpc_anon_lockdown.sql` — revokes + `coalesce(my_role(),'')` |
| **S-05/06** | `my_role()` ignored `is_active`; disabled users retained privilege | `20260720640001_security_p0.sql:14-29` — raises "Account disabled"; cold-restore signs out (`auth.tsx:34-56`) |
| **S-06/07** | `customer_pay_profile()` open to any staff | `20260720640001:32-53` — office-gated |
| **S-07** | `profiles`/roster readable by any login | `20260720720001_profiles_select_narrow.sql` |
| **S-12** | Last-admin protection only in edge | `20260720640001:56-74` — DB trigger (UPDATE; see LOW) |
| **B-01** | Void didn't reopen invoiced accessorials | `20260720640001:107-110` |
| **B-02** | `create_invoice` accessorial race | `20260720640001:140,159-172` — `for update` locks the summed ids |
| **B-03** | Proposals froze stale amounts (`on conflict do nothing`) | `20260720640001:203` / `20260720790001:39` — `do update … where status='proposed'` |
| **B-04** | Invoice UI total ignored accessorials | *Still open — see M-1* |
| **S-09** | CORS `*` / missing headers | `_shared/auth.ts:34-42` origin allowlist; `vercel.json` full CSP + HSTS + nosniff + frame-ancestors |
| — | Number-sequence RPCs burnable by clients | `20260720710001_sequence_grants.sql` — `next_invoice_number` revoked from authenticated |
| — | AR overstated (face vs balance); factoring reserves counted as A/R | `invoice_balance()` across `acct_summary`/`company_scorecard`; `factored_at is null` guards (9 sites) |
| — | Whole-month GL margins on partial window; break-even from zeroed `monthly_cost` + bad MPG window | `20260721030001_scorecard_window_guard.sql`, `exam_fixes.sql:221-300` |
| **B-07** | Mobile sign-out left GPS + queues | Core path fixed (`api.dart:323-334`); *residual race = M-2* |

**Still-open money-metric LOWs** (distortions, not ledger errors): `bad_debt_pct` counts re-bill voids (`factoring_ar_sweep.sql:416,499`); `cashflow_forecast` double-counts recent unbilled (`cashflow_factoring.sql:95-116`); `mtd_collected` understates factored cash vs `weekly_flash` (`factoring_mvp.sql:119`); scorecard `fleet_mpg` uses loaded miles only (`factoring_ar_sweep.sql:510`); IFTA re-bank transient double-count (`20260720650001` vs `rollup_eld_daily`). All self-healing or display-only.

---

## Strengths worth preserving
Constant-time fail-closed `requireCron`; origin-allowlisted CORS on every function; read-only RLS-scoped agent SQL (`trux_query` INVOKER + `transaction_read_only`); propose/confirm agent writes with per-user token ownership; DMARC/SPF/DKIM-gated email intake, blanks-only + reversible + audited; 3-2-1-1-0 backups (gpg over fd 3, Object-Lock offsite, asserting weekly restore test); strong frontend CSP + DOMPurify; `allowBackup=false` + no cleartext traffic on mobile; the whole cross-isolate `AuthRefresher` design.
