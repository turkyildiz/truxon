# Truxon — Stress Test & Security Report (2026-07-16)

Two-part test against the **live** Supabase project: (1) an escalating-load
harness measuring latency and error rates, and (2) a six-vector adversarial
agent fleet (anonymous access, input injection, rate limits/edge functions,
auth storms, storage isolation, workflow races), each finding independently
reproduced before being counted.

## Headline

The infrastructure is **sturdy** — nothing crashed, concurrency logic is
sound, storage isolation is airtight, SQL injection defense holds. The test
found **one critical live security hole and one high-severity broken feature,
both now fixed and verified.** Everything the harness threw at it was handled
gracefully.

---

## Load results — where it slows down

Zero errors up to **200 concurrent users** on every read path. Latency at 200:

| Vector | p95 @ 200 concurrent | Notes |
|--------|----------------------|-------|
| weekly_report | 0.5s | scales well |
| load_detail | 0.4s | scales well |
| global_search | 1.1s | scales well |
| dashboard | 0.7s | scales well |
| list_customers | 1.9s | fine |
| **loads board** | **3.6s** (was 12.2s) | heaviest; **fixed** |

The **loads board** (200 rows × 4 joins) was the one bottleneck — throughput
capped at ~16/s, p95 12s at 200 concurrent. **Fixed** by indexing
`loads(created_at)` and `loads(pickup_time)`: p95 dropped to 3.6s, throughput
~3× higher. No longer a breakpoint at realistic scale.

Other observed platform limits (informational):
- **Login rate limit** is per-IP: Supabase Auth starts 429-ing between ~10–25
  concurrent logins from one IP per 5-min window, auto-recovers in ~60–75s.
  Per-IP, not per-account (no account lockout on bad passwords).
- **PDF extraction**: hard 30/hour/user cap, clean 429 over-limit, 15 MB cap
  with clean 413, no 5xx under burst.
- **Load status / invoicing**: perfect integrity to 20 concurrent on one load
  — exactly one winner, no double-billing, no corruption (`SELECT … FOR
  UPDATE` locking).

---

## Security findings

### 🔴 CRITICAL — Anonymous access to all RPCs — **FIXED**
`dashboard_summary`, `global_search`, and `weekly_report` were callable by
**anonymous** (logged-out) clients, leaking live revenue, driver names, the
full customer roster, load addresses, and **individual driver pay** to anyone
with the public anon key (which ships in the frontend). The load/invoice
mutators shared the flaw.

**Root cause:** guards written `my_role() not in (...)` fail open for anon —
`my_role()` is NULL when logged out, and `NULL not in (...)` is NULL, not
TRUE, so the guard never fires and the SECURITY DEFINER function runs with RLS
bypassed. Introduced by the earlier "RBAC hardening" migration, which replaced
an `auth.uid() is null` check with this pattern.

**Fix (migrations `20260716250001`/`250002`):** revoked EXECUTE from anon on
every RPC (grant only to authenticated) **and** rewrote guards as
`my_role() is null or my_role() not in (...)`. **Verified live:** anon denied
on every RPC and mutator; admin/authenticated unaffected. Direct table access
was already correctly locked (anon gets 0 rows everywhere).

### 🟠 HIGH — Load editing broken — **FIXED**
Editing any audited load column (rate, miles, addresses, times, driver, truck,
trailer, customer) threw `malformed array literal: "rate"`. The audit trigger's
`changed || 'rate'` resolved to array-concat and tried to parse `'rate'` as an
array literal, so **load edits hard-failed** (status changes and invoicing
worked — they touch un-audited columns). Never surfaced because no QA edited a
core load field against production.

**Fix (migration `20260716260001`):** `array_append(changed, 'rate')`.
**Verified live:** editing rate + miles on a load now succeeds.

### 🟡 MEDIUM — No DELETE policy — **FIXED**
RLS was on with no DELETE policy, so even admin deletes silently affected 0
rows — erroneous records couldn't be removed through the app. **Fix (migration
`20260716270001`):** admin-only DELETE policies on loads/customers/drivers/
trucks/trailers/maintenance (FK integrity still guards against orphaning;
non-admins keep soft-delete). Used it to remove the test rows the probes left
behind.

### 🟡 MEDIUM — Login DoS via shared IP — *platform, note only*
The per-IP auth rate limit means a noisy client on a shared IP/NAT can
transiently block real logins (~60–75s, self-recovers). Tune in Supabase →
Auth → Rate Limits if the office is behind one IP with many users. No code fix.

### 🟢 LOW — Unmetered paid APIs — *deferred*
The `distance` (Google Maps) and `admin-users` edge functions have no rate
limit — an authenticated admin/dispatcher could run up cost. Insider-only.
Worth adding the same `check_rate_limit` guard the PDF function uses; queued.

### 🟢 LOW — Misleading concurrent-invoice error — *cosmetic*
Two simultaneous invoices on one load: the loser says "is not completed"
instead of "already invoiced." No double-billing (the invariant holds).

---

## What held up well

- **RLS on all 14 tables** denies anonymous reads — 0 rows, 0 leaks.
- **Storage isolation** is correct: personal/team buckets and `drive_files`
  enforce owner-only / team access at both the table and object layer; no
  cross-user upload, download, listing, or row insert was achievable.
- **SQL injection** defense solid — every payload treated as a literal; bad
  enum/date/array inputs rejected with clean 400s, never 500s.
- **Concurrency** is genuinely well-built — one-winner transitions, billed-
  lock, atomic void-vs-edit, single-invoice — all held to 20 concurrent.
- **Edge functions** fail gracefully — zero 5xx across every abuse probe.

## Net

Four fixes shipped tonight (anon RPC lockdown, load-edit, admin delete, loads
index). Two items deferred with notes (edge-fn rate caps, auth IP limit). The
app is now safe to run; the critical exposure existed only in the RPC layer
and is closed. Probe scripts are in `deploy/stress/` for re-runs.
