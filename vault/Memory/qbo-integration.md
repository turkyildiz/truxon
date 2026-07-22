---
name: qbo-integration
description: QuickBooks Online ↔ Truxon sync — live in transition mode (QBO = books of record, Truxon mirrors); how it's wired and what's left
metadata:
  type: project
  originSessionId: a28d9126-d517-4423-90d2-26d2f9088c49
---

**LIVE since 2026-07-19.** [[project-truxon]] mirrors Aida Logistics LLC's QuickBooks Online (realm `9341451946804768`) in **transition mode**: QBO stays the books of record; the `qbo-sync` edge fn pulls invoices every 30 min (cron `truxon-qbo-pull`, anon-bearer pattern). First backfill: **812 invoices + 93 auto-created customers**. Payments in QBO flip Truxon invoices to paid → AR aging + Sentinel run on real cash. **Push mode** (Truxon-first invoicing, continuing the 45xx DocNumber series) is implemented but disabled behind `QBO_PUSH_ENABLED` — the flip is a setting, not a build.

**Intuit app:** production app "Truxon" in workspace "Truxon" (developer.intuit.com, login = the owner's QBO login, ike@aidalogistics.com profile). Compliance questionnaire passed same-day 2026-07-19 (submitted; not editable afterward). Keys: `QBO_CLIENT_ID`/`QBO_CLIENT_SECRET` Supabase secrets + password manager ("Truxon Intuit app keys"). **Redirect URI gotcha:** must be registered on the app's **Settings → Redirect URIs** tab (NOT the app-details URLs) and match exactly: `https://okoeeyxxvzypjiumraxq.supabase.co/functions/v1/qbo-sync`. The portal SPA is nearly unusable in the embedded browser pane (tab panels don't render, screenshots time out) — React-props onClick works for tabs; for anything fiddly have the owner edit in their own browser.

**Code gotchas (learned live):**
- The connect flow inserts a CSRF-placeholder row in `qbo_connection` BEFORE consent → "connected" must mean `realm_id <> ''` (fixed in 20260719440003).
- Never gate cron calls on exact-match with env `SUPABASE_ANON_KEY` — the 2026-07 key rotation repointed it; decode the bearer JWT and check `role=='anon' && ref==project` instead.
- Intuit refresh tokens ROTATE on every refresh; persist the new one before using the access token.
- QBO MCP connector in Claude sessions = separate plane (analysis/ops on the same realm, works today, read AND write tools).

**GL mirror (2026-07-19, same day):** qbo-sync also pulls the monthly **ProfitAndLoss + BalanceSheet reports** nightly into `gl_monthly` (366 rows, 18 months, 25+ accounts) + `bs_snapshot` — Truxon now sees ALL costs (insurance $172K/6mo, Vendor Expense/driver pay $550K/6mo, factoring, interest…), not just fuel/tolls/MX. Real numbers: revenue $1.94M/6mo, gross 43.3%, net 16.3%. Feeds gl_pnl_monthly (TRUE operating ratio), gl_breakeven_monthly (RPM vs break-even), gl_expense_breakdown, gl_cfo_snapshot (cash days, current ratio, DPO, interest coverage). Flipped playbook #24,25,36,37,38,45,47,48,50,54,86 → **86 live of 1000**. In the QBO-free future the same gl_monthly table takes Truxon-native expense entries.

**Factoring-fee residuals (owner bug 2026-07-20, fixed):** the Aida books leave small residual balances (2-5%, e.g. $132.95 of $2,600) open on factored invoices — the factoring fee never written off — so 158 mirror rows sat 'sent' at FULL total in the forecast even though really paid. Fix (migrations 20260720450001/2): the whole predictive layer (slow_pay_risk, cashflow_forecast, Sentinel slow_pay) uses **OUTSTANDING** (qbo_balance for mirrors, total − invoice_payments for native), a residual gate (≤$200 AND ≤10% of total = fee remnant, excluded from risk), real doc numbers ('#4523') in displays, and `qbo_upsert_invoices` stamps `paid_at` on an OBSERVED sent→paid flip (never on historical imports — no fabricated dates). Diagnostic that found it: `qbo-sync` **mode:debug_dupes** (cron-gated, read-only, kept deployed). Books-hygiene suggestion for the owner: write off factoring fees in QBO so the residuals clear.

**Follow-ups:** sandbox connect/disconnect/reconnect test + intuit_tid header capture (questionnaire answered "not yet" on both); success page renders as raw HTML on some browsers (cosmetic); flip QBO_PUSH_ENABLED after go-live confidence. ~~Customer dedup~~ DONE — verified 2026-07-20 night: `customer-enrich mode:merge_auto` dry-run returns 0 duplicate groups on prod (the task-57 merge completed).
