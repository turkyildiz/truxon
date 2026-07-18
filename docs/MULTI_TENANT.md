# Multi-tenant — design, status, and deploy plan

Goal: run multiple carrier companies from one Truxon install, each fully isolated
(their own customers, loads, drivers, users, etc.), so Truxon can be sold SaaS.

**Status: foundation built and staged on the `multi-tenant` branch. NOT on
`main`, NOT deployed.** It's designed so the two migrations are safe to apply
even with one tenant (zero behavior change), but a second tenant must NOT be
onboarded until the RPC work below is done and tested.

---

## How it works
1. **`tenants` table** — one row per company. The current company is seeded as
   `aida`.
2. **`tenant_id` on every business table** + on `profiles` (a user belongs to
   one tenant). All existing rows/users backfilled to `aida`.
3. **`my_tenant_id()`** resolves the caller's tenant from their profile.
4. **Auto-stamp trigger** sets `tenant_id = my_tenant_id()` on every insert, so
   app code never passes it and can't get it wrong.
5. **Restrictive RLS** (`tenant_isolation` policy per table) ANDs a
   `tenant_id = my_tenant_id()` check on top of the existing 72 role policies —
   no existing policy is rewritten.

Files: `supabase/migrations/20260718000001_multitenant_foundation.sql`,
`20260718000002_multitenant_enforce.sql`.

## Why it's safe to apply now (one tenant)
With one tenant, `my_tenant_id()` = aida for everyone, so every
`tenant_id = my_tenant_id()` test is always true. Behavior is identical to
today. The isolation only "switches on" when users in a *second* tenant exist.

## ⚠️ The real remaining work — REQUIRED before onboarding tenant #2
SECURITY DEFINER RPCs run as the table owner and **bypass RLS**, so the
restrictive policies do NOT protect data returned through them. Each of these
must get an explicit `... where tenant_id = public.my_tenant_id()` (reads) or a
tenant ownership check (writes):

**✅ DONE — phase-3 migration `20260718000003_multitenant_rpcs.sql` (2026-07-18):**
- **Reads / aggregates** now tenant-filtered: `dashboard_summary` ·
  `weekly_report` · `global_search` · `fleet_positions_snapshot`.
- **Per-tenant numbering** fixed. NOTE: the numbering was worse than first
  thought — `load_number`/`invoice_number` were **globally UNIQUE**, so a 2nd
  tenant would collide on `INV-YYYY-0001`. Phase-3 swaps those for composite
  `unique (tenant_id, number)` and adds an atomic per-tenant counter table
  (`tenant_number_counters`) driving `next_load_number`/`next_invoice_number`.
- Validated: all 3 migrations + 12 PL/pgSQL bodies parse clean against the real
  Postgres grammar (libpg_query). **Not yet run live** — see test section below.

**✅ DONE — write RPCs, phase-4 migration `20260718000004_multitenant_write_rpcs.sql`:**
- `create_invoice` · `void_invoice` · `set_invoice_status` · `change_load_status`
  now AND `tenant_id = my_tenant_id()` on their id lookup, so a foreign id →
  "not found" instead of a cross-tenant mutation. `ingest_vehicle_positions`
  needed no change — it only writes the caller's own driver (`my_driver_id()`).
- The isolation test now also asserts A cannot `change_load_status` /
  `create_invoice` on B's rows.

**Driver RPCs (already user-scoped via `my_driver_id`; verify, low risk):**
- `driver_my_loads` · `driver_get_load` · `driver_load_dto` ·
  `driver_list_documents` · `driver_change_load_status` · `driver_set_duty` ·
  `driver_add_document`

## App layer — ✅ DONE (phase-5 migration + edge fns + UI, 2026-07-18)
- **New-user tenant stamping:** `handle_new_user` now reads `tenant_id` from user
  metadata; `admin-users` supplies it (creating admin's tenant, or a chosen
  tenant for a super-admin). New users land in the right tenant, not null.
- **admin-users is now tenant-scoped:** GET lists only the caller's tenant;
  POST stamps the new user's tenant; PATCH refuses foreign-tenant ids; the
  last-admin guard is per tenant. (It previously leaked across tenants because
  the service role bypasses RLS.)
- **Platform super-admin:** `super_admin` flag on profiles + `my_is_super_admin()`;
  `create_tenant()` RPC (super-admin only); RLS on `tenants` (a normal user sees
  only their own). New `create-tenant` edge function creates a company + its
  first admin. Frontend: super-admin-only **Tenants** page (`/tenants`, gated in
  the router + nav) to onboard a company.
- Still optional/nice-to-have: per-tenant name/logo in the header; confirm
  storage bucket policies gate on tenant (buckets are already RLS/owner-scoped).

### ⚠️ Bootstrapping the first super-admin (one-time, manual)
No super-admin exists until one is set by hand (there's no super-admin yet to
create one). After deploying, run once against prod:
```sql
update public.profiles set super_admin = true
 where id = (select id from auth.users where email = 'turkyildiz@gmail.com');
```

## Isolation test (written, awaiting a DB to run)
`supabase/tests/multitenant_isolation_test.sql` seeds a 2nd tenant + a probe
admin in each tenant + one row of every business table per tenant, then
impersonates each probe (via `request.jwt.claims`) and asserts: table RLS
isolation, RPC scoping (`dashboard_summary`/`global_search`/etc.), and
per-tenant numbering with no unique-constraint collision. It runs in ONE
transaction and ROLLS BACK (non-destructive). Run once a DB is available:
```bash
psql "$BRANCH_DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/multitenant_isolation_test.sql
```
**✅ VERIFIED 2026-07-18 — ALL ISOLATION TESTS PASSED.** Ran on a real Supabase
preview branch (Pro enabled briefly, branch created, all 4 multi-tenant
migrations applied via `supabase db push`, test run via node-pg over the IPv4
session pooler, branch then deleted). Confirmed live with two tenants: table
RLS isolation; `dashboard_summary` scoped (A=$1000 / B=$2000, no bleed);
`global_search` scoped; per-tenant numbering with both tenants holding
`load_number DUP-0001` and no collision; and write-RPC ownership (tenant A
cannot `change_load_status`/`create_invoice` on tenant B's rows). Phase 1–4 are
now behavior-verified, not just syntax-verified.

## Verified on a branch (2026-07-18)
A second branch (`mt-verify`) applied ALL FIVE migrations and ran both suites
green: `multitenant_isolation_test.sql` (phases 1–4) and
`multitenant_onboarding_test.sql` (phase 5 — tenant stamping, super-admin-only
`create_tenant`, tenants RLS). Frontend `npm run build` passes with the new
Tenants page. Edge functions (`admin-users`, `create-tenant`) are written and
DB-verified but NOT yet deployed (the classifier blocks Claude from
`functions deploy`; that's an owner step).

## Deploy runbook (turn multi-tenancy on — still gated by the owner)
Everything below is staged on the `multi-tenant` branch. To go live:
1. (Optional but recommended) Re-run the branch verification: create a preview
   branch, `supabase db push`, run both test SQL files, confirm all PASS.
2. Merge `multi-tenant` → `main`.
3. Apply migrations to prod: `supabase db push` (adds phases 1–5; zero behavior
   change with one tenant).
4. Deploy edge functions: `supabase functions deploy admin-users create-tenant`.
5. Bootstrap the first super-admin (SQL above).
6. As super-admin, open **Tenants → New company** to onboard tenant #2, then
   verify with a probe login. Old flow (single tenant) is unchanged throughout.

### Legacy manual test steps (still valid for a full end-to-end check)
4. Create a **second tenant** + a probe user in each tenant. Verify:
   - each user sees ONLY their tenant's loads/customers/drivers (UI + direct RPC),
   - a new load in tenant B is invisible to tenant A,
   - load/invoice numbers restart per tenant,
   - Track & Trace shows only your tenant's trucks.
5. Only after all green: merge to `main`, apply the migrations to prod
   (`supabase db push`), redeploy the RPCs.
6. Prod is single-tenant and unchanged until you create tenant #2.

**Bottom line:** the schema + isolation guardrail are done and low-risk. The
RPC filtering + onboarding UI + a two-tenant test are the remaining, deliberate
steps — best done together, not blind. Everything here is on the `multi-tenant`
branch awaiting that.
