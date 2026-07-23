---
name: denim-factoring
description: "Denim factoring integration — LIVE 2026-07-22 (owner provided the API key). denim-sync reconciles factoring jobs into invoices every 2h; read-only, no money movement."
metadata:
  type: project
---

**Denim factoring sync — activated 2026-07-22** (owner pasted the API key in chat; Claude stored it, never committed). Prior to this it was dark-launched/dormant ([[qbo-integration]] sibling; task #119 "Denim dark-launch").

**Wiring:** `denim-sync` edge function, auth `x-api-key`, base `https://app.denim.com` (`DENIM_BASE_URL` overridable to staging). Gated admin-or-cron. **`DENIM_API_KEY` is set as a Supabase edge secret on prod** (`okoeeyxxvzypjiumraxq`) — verified working (`GET /api/v1/jobs` → HTTP 200 with real jobs). Cron **`truxon-denim-sync`** `25 */2 * * *` runs the default **pull**: read Denim jobs → match to invoices by reference → write factored status/fees **metadata only**. **No money movement** — QBO remains the money source of truth; there is NO invoice-push-to-Denim path. `mode:status` is a read-only connectivity probe.

**⚠ DR / vault:** the key currently lives ONLY as a Supabase edge secret. **Owner: add `DENIM_API_KEY` to the [[secrets-vault]] KeePassXC vault** so it survives a Supabase re-provision. Also: pasting keys in chat lands them in the local (gitignored) transcript — fine, but the password-manager/credential path is cleaner next time.

Related: [[qbo-integration]], [[secrets-vault]], [[security-posture]].

**R9 (2026-07-23):** fees now FLOW — live payloads carry fees as `type:'earnings'` + `subtype:'factoring_fee'/'servicing_fee'` (type-only matching missed every real fee; jobFee checks both). `denim_jobs` mirror banks every job per pull; `denim_reconciliation()` compares statement vs books (launch: $21,844 Denim vs $18,389 captured, 350/471 matched, 0 per-invoice mismatches). Cost of factoring measured: **effective 1.99%, ~5.3% annualized vs 139-day book pay speed** — cheap money, provable. Fee write-off proposals (116 / $17,359) are propose-only; owner approves → accountant packet → QBO mirror clears.
