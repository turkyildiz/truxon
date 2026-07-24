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
