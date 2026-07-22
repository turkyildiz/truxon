---
name: week-standard
description: "Truxon's canonical week definition — always use it, never reinvent week math"
metadata: 
  node_type: memory
  type: project
  originSessionId: a28d9126-d517-4423-90d2-26d2f9088c49
---

Truxon standardized weeks as of 2026-07-20 (migrations 20260720240001 + 240002).

**Definition:** Week = Monday→Sunday, numbered by how many Mondays have passed since Jan 1. If the year doesn't start on a Monday, the partial run Jan 1→first Sunday is **Week 0**; Week 1 starts the first Monday. A year that starts on a Monday has no Week 0. "Same week last year" is anchored **by week number** (Week N ↔ Week N), NOT by a rolling 364 days (the old dashboard method — deliberately replaced).

**Single source of truth — use these, don't hand-roll `isodow`/`date_trunc('week')`/ISO weeks:**
- SQL (all IMMUTABLE): `trux_first_monday(year)`, `trux_week_number(date)`, `trux_week_year(date)`, `trux_week_start(date)`, `trux_week_end(date)`, `trux_week_label(date)` → 'YYYY-Www', `trux_week_range(year, week)` → (start,end).
- Frontend: `frontend/src/lib/week.ts` mirrors the SQL exactly (weekNumber/weekStart/weekEnd/weekLabel/weekRange/weekTitle).

**Adopted in** `weekly_report` and `dashboard_summary` (both now emit `week_number`/`week_label`). Everything else that says "this week" (Sentinel unprofitable-truck checks, exec reports) calls `weekly_report()` and inherits it — so new weekly logic should route through these, not add its own week math. Note: `extract(week ...)` is ISO-8601 (week-with-first-Thursday, no Week 0) and does NOT match this scheme.

Related: [[project-truxon]], [[finish-before-next]].
