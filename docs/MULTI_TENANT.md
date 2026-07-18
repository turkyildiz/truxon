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

**New-user path:** `admin-users` edge function must set `tenant_id` on the new
profile (to the creating admin's tenant, or a chosen tenant for a platform
super-admin). `handle_new_user` should default `tenant_id` to the inviter's
tenant. Without this, new users get `tenant_id = null` and see nothing.

## App changes still needed
- **Platform super-admin** surface to create tenants and their first admin user.
  (A `super_admin` flag on profiles that a service-role edge function checks —
  restrictive RLS keeps normal admins inside their own tenant.)
- `admin-users` create path passes `tenant_id`.
- Optional: tenant name/logo in the header (company branding per tenant).
- Storage paths + `documents`/drive buckets are already RLS-scoped; confirm the
  bucket policies also gate on tenant once RPCs are filtered.

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
**Blocked locally 2026-07-18:** this workstation has no Docker/Postgres (both
need a root install) and Supabase **branching requires the Pro plan** ($25/mo),
which we did not enable. So the live 2-tenant run is deferred until either a
container runtime is installed or the project is briefly on Pro. Until it runs
green, treat phase-3 as syntax-verified but not behavior-verified.

## Deploy runbook (do WITH a test DB — do not rush this)
1. **Create a Supabase preview branch** (Dashboard → Branches; needs Pro) so you
   have a throwaway copy of prod.
2. On the branch, apply all three migrations: `supabase db push`.
3. Run the isolation test above; confirm `ALL ISOLATION TESTS PASSED`.
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
