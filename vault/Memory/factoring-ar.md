---
name: factoring-ar
description: "Aida factors its invoices; AR shows them as \"short paid\". Design + what to extract from the factoring agreement (owner uploading ~2026-07-22)."
metadata: 
  node_type: memory
  type: project
  originSessionId: a28d9126-d517-4423-90d2-26d2f9088c49
---

**Problem (raised 2026-07-21):** Aida uses **invoice factoring**. The factor advances
~90% immediately and releases the ~10% reserve (minus a fee) later, once the broker
pays the factor. In Truxon's Receivables (/invoices) these show as **short-paid /
past-due** because `invoice_balance()` = `total − payments` and an invoice only flips
`paid` at a ZERO balance. Two wrongs: (1) once factored, the FACTOR owns collecting
from the broker — so past-due/dunning/Sentinel-AR on the broker is a false signal;
(2) the factoring fee means payments never net to zero without booking the fee as an
expense.

**Current model:** invoices (status draft/sent/paid/void; total; paid_at) +
`invoice_payments` (amount, method, received_at) + `record_invoice_payment()` (flips
paid at zero balance) + `invoice_balance()` (QBO rows trust qbo_balance; Truxon rows
compute total−payments). See [[qbo-integration]]. NO factoring concept exists yet.

**Recommended design (agreed direction):** a factored invoice has THREE money events —
advance (~90%), reserve release (~10% − fee), and the fee (an EXPENSE/contra-revenue,
via the GL mirror). When marked **`factored`** it should LEAVE broker
collections/aging (no dunning, no Sentinel AR finding) and move to a new **Factoring
view** (advance received / reserve pending / fee). Reconcile from the factor's
remittance/settlement report (per-invoice advance/reserve/fee) — auto-import ideal.

**MVP SHIPPED + LIVE 2026-07-21 (commit a170990, migrations 234001/234002):**
invoices.factored_at/factor_name/factoring_fee + mark/unmark_invoice_factored() +
factoring_overview() RPC + a "🏦 Factoring" tab on /invoices. acct_summary &
acct_aging now EXCLUDE factored invoices from broker A/R/past-due (acct_summary adds
factoring_reserve/factored_count). Backfill marked the 118 QBO short-paid open
invoices factored (they were the culprit — reserve in qbo_balance, no
invoice_payments row): $346k factored, $327.6k advanced (~94.6% advance rate!),
**$18,650 reserve pending** pulled out of past-due. Fees still $0 (TBD). The Denim
API sync replaces the manual backfill later + fills advance/reserve/fee per job.

**Waiting on the OWNER (as of 2026-07-21):** he'll find the **factoring agreement**
and upload it ~2026-07-22. From it, extract: advance rate (flat 90% or per-broker),
fee structure (flat % vs tiered by days), factor name, **recourse vs non-recourse**,
and whether a remittance file exists (CSV/PDF → build importer, forward to trux@).
Build it RIGHT once the agreement lands; MVP is ready to start on his signal.

**FULL A/R SWEEP DONE (migration 20260721236001, commit 04198e2):** after the MVP,
a site audit found 9 MORE functions counting factored reserves as customer debt —
ar_aging (also switched face-total→invoice_balance), collections_queue,
slow_pay_risk, customer_exposure, customer_profile, weekly_flash, company_scorecard,
capture_metric_snapshots (ar.over_45/60), sentinel slow-pay finding. All now guard
`factored_at is null`. RULE for any future A/R-reading function: exclude factored.
Verified: collections queue 34→3 customers ($31k→$20.1k true), slow_pay 0 factored.
NOTE: ar_aging-style `language sql` fns use `where my_role() in (...)` as the gate —
they return 0 rows for a service-role session (not a bug; test with a real sub).

**FACTOR = Denim (denim.com), API-native (confirmed 2026-07-21).** This replaces the
manual-remittance plan — pull the truth live instead of guessing advance/fee. OpenAPI
spec: `https://app.denim.com/api/v1/open-api-specs`. Auth: **`x-api-key` header**
(simple API key — owner generates in Denim; store secret `DENIM_API_KEY`). Prod
`app.denim.com`, staging `staging.denim.com`. Amounts are in **CENTS (integer)**.
Model maps cleanly:
- **Job** = an invoice/load. `reference_number` (unique) = our invoice_number → the
  match key. `status`: draft/pending/approved/rejected/completed. Has `obligations[]`.
- **Obligation** (receivable / payable / **fee**): `total_amount` (cents),
  `line_items[]` {amount, type: base_amount|accessorial_fee}, `payment_status`
  (pending/fully_paid/overpaid/underpaid/expected/scheduled), `due_date`. The FEE is
  its own obligation → book to factoring-expense.
- **Transaction**: `type` (incoming/outgoing/netting/adjustment), `total_amount`
  (cents), `applied_transactions[]`{applied_amount} → obligations, `transaction_date`.
  Advance + reserve-release show up here as incoming.
- Endpoints: GET /api/v1/jobs (+ /api/v2/jobs), GET /api/v1/jobs/{id}, GET
  /api/v1/transactions, GET /api/v1/companies/factors. Pagination: page / per_page →
  total_pages / total_results.

**Build plan (QBO-sync pattern):** `denim-sync` edge fn on a cron — pull jobs +
transactions, match to Truxon invoices by reference_number, mark `factored`, post
advance+reserve as invoice_payments, fee → GL expense, use Denim `payment_status` as
source of truth, and drop factored invoices from broker collections/aging/dunning.
**denim-sync BUILT + DARK-LAUNCHED (commit 23f6ec2):** edge fn deployed, 2h pg_cron
live, returns {skipped} until `supabase secrets set DENIM_API_KEY=…` (+optional
DENIM_BASE_URL=https://staging.denim.com for testing). v1 = metadata only (match by
reference_number → denim_job_id/factored_at/factor_name/factoring_fee from fee
obligations, cents→dollars); NO payment writes — QBO stays money truth. modes:
status (connectivity probe) / pull (default, ?pages=N). invoices.denim_job_id added.
pgTAP test 89 (10 asserts) locks the factoring exclusions; sentinel
`factor_reserve_stuck` fires when a reserve is unreleased 45d+ (critical 75d).
**Remaining owner steps: paste the Denim API key; upload the agreement (fees %).**

Related: [[project-truxon]], [[qbo-integration]], [[customer-enrichment]].
