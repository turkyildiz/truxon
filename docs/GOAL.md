# North Star — The Owner's Playbook

**The goal:** make Trux a true C-suite for Aida Logistics — able to answer the
owner's accountability questions and report the metrics that actually run a
trucking company, honestly, from real data.

The blueprint is *The Owner's Playbook* (kept here as the source of truth):

- [`Trucking_CSuite_Owner_Playbook.docx`](Trucking_CSuite_Owner_Playbook.docx) — 100 questions + 100 metrics
- [`Trucking_CSuite_Owner_Playbook_1000.docx`](Trucking_CSuite_Owner_Playbook_1000.docx) — **the north star**: 1,000 questions across 26 role areas + 1,000 metrics across 8 categories

## How we get there (the honest way)

Reaching 1,000 is **not** 1,000 hand-coded reports. It's a **living catalog**:
every metric lives in `public.playbook_metrics` with a status —

| status | meaning |
|---|---|
| `live` | computed today from Truxon data |
| `needs_data` | reachable by instrumenting Truxon (new fields/tables) |
| `external` | needs a vendor feed (ELD/telematics, FMCSA SMS, DAT rates, insurance) |
| `qualitative` | a board judgment, not a computed number |

As we instrument each data source, its metrics flip `needs_data → live` and
coverage rises. Trux reports progress via `playbook_coverage()` and, for any
metric that isn't live, states plainly what it would take — **it never
fabricates a number.**

## Coverage (starting line)

| status | count |
|---|---|
| live | 75 |
| external | 44 |
| qualitative | 18 |
| needs_data | 863 |
| **total** | **1,000** |

Live today: the exec **scorecard** (~40 financial/ops/revenue/maintenance
metrics), the **safety** module (accidents/OOS/HOS/claims), **fuel & toll**
analytics, P&L **budget variance**, and the **maintenance** module —
Maintenance CPM, Tire CPM, PM Compliance %, and Deadlined Tractors %, backed by
a real PM/inspection due engine (mileage from the fuel-card odometer) and the
Sentinel's overdue-PM / repeat-breakdown / stale-work-order alerts.

## Instrumentation roadmap (biggest converters first)

1. **Budgets & variance** — ✅ done
2. **Detention & accessorials** — COO/CFO revenue-leak cluster
3. **Driver lifecycle** — the CHRO cluster (~136 metrics: turnover, cost-per-hire, 90-day, tenure)
4. **External feeds** — ELD/telematics (HOS, idle, harsh, MPG-by-driver), FMCSA SMS (CSA BASICs), DAT (market rates), insurance (loss ratio)

Rule of the house (from the playbook): *no metric without an owner, no red
metric without a 30-day action, no answer without a number when a number
exists.*
