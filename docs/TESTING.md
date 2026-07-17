# Truxon testing

This repo includes a security- and workflow-focused harness that can run offline
(static review of migrations + frontend build) or against a local/staging
database (SQL workflow checks).

## Quick start

```bash
# From repo root — frontend build + static security review
./scripts/run-truxon-tests.sh

# Static security only (no Node required)
./scripts/run-truxon-tests.sh static-security

# Frontend typecheck + production build only
./scripts/run-truxon-tests.sh smoke

# SQL workflow tests (requires DATABASE_URL or local `supabase start` + psql)
export DATABASE_URL='postgresql://…'
./scripts/run-truxon-tests.sh sql

# Everything
./scripts/run-truxon-tests.sh all
```

## What is checked

| Suite | ID range | Contents |
|-------|----------|----------|
| Smoke | A1–A4 | Frontend build, migrations present, edge functions present |
| Static security | B1–B11, C1, C6 | DEFINER RPC role gates, storage RLS, search filter safety, void paid, workflow locks |
| SQL | C1–C3… | Direct status update blocked, change_load_status step rules (see `supabase/tests/rls_and_workflow.sql`) |

### Phase 0 security (companion prerequisites)

Migrations `20260716200001_phase0_security.sql` and `20260716200002_phase0_driver_link.sql` close the former baseline failures:

| Check | Fix |
|-------|-----|
| **B1 / B2** | `dashboard_summary` / `global_search` gated with `my_role()` staff allow-list |
| **B6** | Storage + `documents` SELECT/INSERT restricted to staff roles |
| **B11** | `sanitizeSearchTerm()` before PostgREST `.or()` / `ilike` |
| **C6** | `void_invoice` rejects `status = paid` |
| **C7 / C8** | Advisory locks on numbering; `assert_no_double_booking` |
| **D1** | `driver_load_dto` internal-only (no `authenticated` EXECUTE grant) |

CI job **security-static** is a **hard gate** (no `continue-on-error`).

## Live / E2E scripts (existing)

Require a real project and credentials — **do not run against production carelessly**.

```bash
cd frontend
# 27-check smoke against env in .env.local
node scripts/e2e_smoke.mjs

# Feature-batch QA (login + settings + password change)
node scripts/qa_features.mjs <email> <password>
```

## Local Supabase SQL tests

```bash
supabase start
supabase db reset          # applies migrations — destructive on local only
export DATABASE_URL="$(supabase status -o env | sed -n 's/^DB_URL=//p' | tr -d '"')"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/rls_and_workflow.sql
# or:
./scripts/run-truxon-tests.sh sql
```

## Adding tests

1. Prefer new checks in `scripts/run-truxon-tests.sh` (static) or `supabase/tests/*.sql` (runtime).
2. Never edit an already-applied migration to “make a test pass” — add a new migration for product fixes.
3. For role denial tests, assert as the restricted role (driver / maintenance), not only as admin.

## Related agent (optional)

A Grok skill/agent that orchestrates this harness lives on developer machines as
`/truxon-test` (user skill). The **source of truth for CI** is this repository’s
`scripts/` and `supabase/tests/` only.
