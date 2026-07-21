# Forest Final Exam — 100 Owner Questions (2026-07-20 overnight)

All 100 questions from *The Owner's Playbook* Part One were asked verbatim to the
deployed Forest agent (prod, dedicated `forest-exam` admin user — deactivated
after), every answer graded against ground truth pulled from the same prod RPCs
plus read-only SQL, defects fixed, failures re-run to green.

## Before → After

| | Before | After fixes |
|---|---|---|
| Grounded, correct, or honestly-scoped answers | 55 | **96** |
| Partial (right direction, weak execution) | 18 | 4 |
| Hard failures | 27 | **0** |

The 4 remaining partials are answers that are correct but stop short of the
best available tool (e.g. Q24 didn't reach `detention_events`). No answer
fabricates, misroutes, or dead-ends anymore.

## Defect classes found and fixed

1. **Announce-then-stop** (24 questions): "Let me pull the P&L…" with no data.
   Three stacked root causes in `truxcore.ts`:
   - 22s deadline / 3 rounds discarded gathered tool results → chat door now
     runs a 100s deadline, 5 rounds, and a tools-off **final compose** pass
     that salvages an answer from tool results when time runs out.
   - The model announcing without calling any tool → announce-detection now
     retries with **`tool_choice: any`** (a forced tool call, not a polite ask).
   - The model calling a *report function name* as a tool name fell out of the
     loop with the preamble → unknown-tool feedback now keeps the loop alive
     and teaches the correct `query_data` form.
2. **Scorecard AR 3× overstated**: `company_scorecard` summed invoice face
   totals ($483K) where true outstanding (factoring residuals, partial
   payments) is $156K. Now `invoice_balance()`-based; DSO 45.9 → 14.8.
   (`weekly_flash` and `acct_summary` were already correct — the exam caught
   the scorecard contradicting them.)
3. **Booking-panel break-even wrong 2.5×**: `fleet_cost_basis` divided 90 days
   of miles by 20 days of fuel (28.65 "MPG") and read fixed costs from
   `trucks.monthly_cost` (all zeros) → $0.85/mi break-even on the live Dispatch
   margin panel. Rebuilt: coverage-window MPG (5.79) + break-even anchored to
   the **GL's all-in cost per mile, trailing 3 full months → $2.14/mi**
   (avg RPM $2.83 ⇒ real cushion ≈ $0.69/mi, not $1.98).
4. **Bare customer IDs** in pay-behavior answers: `customer_pay_profile()` now
   returns the customer name.
5. **Capability ignorance**: Forest claimed CSA percentiles weren't wired
   (they live in `safety_csa`) — catalog now says so; cashflow-forecast
   catalog note explains factoring vs book-payment timing so an "empty"
   4-week forecast is explained, not alarming.
6. **Stale $0 auto-budget lines**: July seeded fuel = $0 because the trailing
   window predates the July 1 fuel backfill. `ensure_auto_budget` now heals
   auto-basis $0 rows when real averages appear (manual rows never touched).
   July's fuel budget stays honestly unknowable; August self-resolves.

One confirmed hallucination (Q83 claimed "$60K unbilled"; truth: 2 loads,
$9K, five days old) — the tool-forcing + failure-honesty rules target exactly
this class; its re-run answered from real numbers.

## Known-inflated until ~Aug 1

`company_scorecard.operations.fleet_mpg` (9.22) still divides window miles by
partial-coverage fuel; it self-corrects as AtoB data accrues past a full
window. The booking panel no longer depends on it.

## Receipts

Migrations `20260720570001_exam_fixes.sql`, `20260720580001_budget_zero_heal.sql`;
pgTAP `61_exam_fixes_test.sql` (8), `62_budget_heal_test.sql` (3); suite 61
files green before 62 landed, 62 green individually. `truxcore.ts` + `llm.ts`
(tool_choice plumbing) + `trux-agent` deadline; all three doors redeployed.
Exam harness + full Q/A transcripts: session scratchpad `exam/` (ephemeral).
