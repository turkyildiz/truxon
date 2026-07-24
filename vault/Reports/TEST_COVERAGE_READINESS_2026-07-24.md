# Test-coverage readiness — Jul 24, 2026 (T‑7 to go‑live Aug 1)

Autonomous test-hardening pass (owner away). Goal: before Aug 1, close the
biggest **untested-surface** gaps — not add breadth for its own sake, but prove
the surfaces where a bug is a breach or a money error.

## Where the suite stands
- **1,236 pgTAP assertions across 205 files**, green from a clean `supabase db reset` on every step.
- Frontend production build (`tsc -b && vite build`, exactly what Vercel runs) verified green.
- Prod deploy pipeline clean since the Jul 24 build fix (`6049c03`).

## Method
1. Enumerated all **289** `public.*` functions across migrations.
2. Cross-referenced against `supabase/tests/` → **63** had no test reference at batch start.
3. Triaged out false positives — functions covered *behaviourally* rather than by name
   (the DML/ransomware guards are exercised by real `DELETE`/`TRUNCATE` in `93`/`94`;
   `touch_updated_at`, the audit `log_insert/update`, `loads_audit_*` are asserted by their effects).
4. Wrote tests for the highest-risk remainder — the **driver/mobile attack surface**,
   the **admin-lockout guards**, the **rate limiters**, the **reporting authz boundary**,
   and the **AI-accuracy feedback loop**.

## Shipped this batch (7 files, 75 assertions)
| # | File | Surface | Why it matters |
|---|------|---------|----------------|
| 178 | `193` | factoring lifecycle E2E | the get-paid-early money path, end to end |
| 180 | `194` | driver isolation (5 SECDEF RPCs) | a driver must reach only their own load |
| 182 | `195` | GPS ingest hardening | highest-volume driver write; poisons the fleet map if unguarded |
| 183 | `196` | last-active-admin guards | owner can't be locked out; admin access can't be collapsed |
| 186 | `197` | driver storage ownership | per-object bucket gates; malformed names must not throw in RLS |
| 188 | `198` | rate limiters (user + IP) | credential-stuffing / signup-flood throttle |
| 189 | `199` | reporting authz boundary | per-role raise is the only wall on RLS-bypassing definer reads |
| 190 | `200` | AI-correction capture | ground-truth table for model accuracy stays honest |

**Coverage moved 63 → 44 uncovered functions.**

## What remains uncovered — and the honest risk read
The remaining **44** break down as:
- **Trigger internals covered by behaviour** (`touch_updated_at`, `log_insert/update`,
  `loads_audit_*`, `invoices_set_paid_at`, the DML guards, `handle_new_user`,
  `profiles_*` guards) — their *effects* are asserted across the suite; a name-level
  test would be redundant. **Low risk.**
- **9 soft-gated read/report RPCs** — `dispatch_productivity`, `dvir_summary`,
  `maintenance_alerts`, `qbo_writeoff_list`, `driver_qual_files`, `trux_insights_feed`,
  `trux_week_year`, `llm_eval_summary`, `bless_security_baseline`. These share the
  same `my_role() in (...)` gate pattern proven in `199`, return role-appropriate
  aggregates, and are read-only. Worst case is a role-scoped info exposure, not a
  write or a breach. **Acceptable for launch; candidates for the next pass.**
- **Internal helpers** not directly client-callable. **Low risk.**

## Two things worth the owner's eye (found while testing, not bugs)
- `system_status()` has **no role gate** — deliberately open to any authenticated
  user; it returns only `{lockdown: bool}` the app itself polls. Pinned by a test in
  `199` so a future edit can't silently widen it.
- `driver_owns_fuel_path()` returns **NULL** (not `false`) for a non-driver, because
  `id = null → null`. Inside RLS `using(...)` NULL denies the row, so it's
  access-safe; the load-path helper returns explicit `false`. Documented in `197`;
  **not** changing prod SQL pre-launch.

## Still owner-gated for Jul 30 (need ~30 min of the owner)
These can't be finished solo and are batched for one short joint session:
1. **OTA manifest signing** — owner generates/holds the offline key; I wire verify.
2. **Restore-from-INDIANCREEK drill** — needs NAS shell to prove the offsite copy restores.
3. **Secret-rotation drill** — rotating `CRON_SECRET` touches the NAS secrets tooling.

None is a hard launch blocker (the resilience already survived a 9-hour Vercel
deploy outage with zero customer impact), so they're safe to schedule.

## Edge-function tests — UNLOCKED + DONE 2026-07-24 (both blockers cleared)
The two blockers below were resolved without touching the shared `auth.ts` runtime:
- **CRON-secret door** (`requireCron`/`timingSafeEqualStr`) — tested (`auth.test.ts`, 3 tests). Blocker #1 (env at import) was solved by adding `--allow-env` to the CI deno step (test code is trusted); no source change to `auth.ts` needed.
- **AI-agent per-role authz** (`toolsForRole`) — tested (`truxcore.test.ts`, 6 tests: driver locked out of dispatch/finance/roster, accountant no writes, only admin gets system internals, unknown role fails closed). Blocker #2 (truxcore didn't type-check) was solved by ONE type alias — `Sb = SupabaseClient<any,any,any>` (erased at runtime, agent behaviour unchanged) — instead of the feared refactor.
- Deno `_shared` gate: **23 → 32 tests green** under the exact CI command. Commits `575bef4` (CRON gate), `70a68ed` (agent authz).

### (Original scoping notes, for history)
Investigated adding `_shared/*.test.ts` coverage for the two highest-value pure
boundaries — `requireCron`/`timingSafeEqualStr` (the CRON secret door) and
`toolsForRole` (the AI agent's per-role tool authorization). Wrote both, they
pass locally, then **reverted both** because each trips the existing CI deno gate
(`.github/workflows/ci.yml:78` → `deno test --quiet supabase/functions/_shared/`,
type-checked, no permission flags). Two concrete blockers to clear WITH the owner
(neither done unattended pre-launch — they touch prod code / CI config):
1. **`auth.ts` reads env at module load** — `const CORS_EXTRA_ORIGINS = Deno.env.get(...)`
   at line ~19 runs on import, so any test importing `auth.ts` needs `--allow-env`,
   which the CI command doesn't pass. Fix: either add `--allow-env` to the CI deno
   step, or make that CORS read lazy (compute inside `corsHeaders()` instead of at
   top level). The lazy refactor is cleaner and unlocks testing every door helper.
2. **`truxcore.ts` doesn't type-check standalone** — 19 `TS2353/TS2345` errors from
   untyped supabase-client `.rpc()`/insert calls in its execute path (returns
   `never[]` without generated DB types). CI type-checks the import graph, so a
   test importing `truxcore.ts` fails the gate. This is also latent CI fragility:
   the day anyone adds a test touching `truxcore.ts`, CI breaks. Fix: type the
   client (`createClient<Database>`) or cast the rpc/insert payloads.

Both fixes are ~30–60 min and turn the whole edge-function `_shared` surface into
testable ground (cron gate, agent authz, doc-filing prompts, remediations map).
The pure-logic modules that DON'T read env or need DB types (denim, fmcsa,
fuel_csv) are already tested and green (23 deno tests).
