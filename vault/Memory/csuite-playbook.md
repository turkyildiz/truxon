---
name: csuite-playbook
description: "The Owner's Playbook (100 questions + 100 metrics) — the spec for Trux-as-C-suite"
metadata: 
  node_type: memory
  type: reference
  originSessionId: a28d9126-d517-4423-90d2-26d2f9088c49
---

Two editions in `~/src/truxon/`: `Trucking_CSuite_Owner_Playbook.docx` (100 Q + 100 metrics) and `Trucking_CSuite_Owner_Playbook_1000.docx` — the NORTH STAR ("this is our goal to achieve"): 1000 questions across 26 role areas + 1000 metrics across 8 categories, each with definition + owner. Metric owners: CFO 203, Safety 174, COO 153, CHRO 136, CRO 112, Maint 107, IT 42, then CX/Procurement/Legal/Brokerage/Dedicated/OO/ESG/Quality/Facilities/CEO/etc. The playbook itself says: pick 30-50 for the exec scorecard, keep the rest as diagnostic drills. Cadence: weekly ops/cash/safety flash, monthly full scorecard, quarterly strategy. Rule: no metric without an owner, no red metric without a 30-day action.

Reaching 1000 ≠ 1000 bespoke functions. The path is a METRIC CATALOG/REGISTRY (id, name, category, owner-role, definition, target, unit, cadence, source-status live|needs-data|external, compute pointer) seeded from the doc, so each metric flips needs-data→live as its source is instrumented, and Trux reports coverage (X/1000 live). Already live: ~40 in company_scorecard + safety module. Instrumentation order by leverage: (done) safety_events; next detention/accessorial capture, budgets/variance, then external integrations (ELD/telematics for HOS/idle/harsh, FMCSA SMS for CSA, DAT for market rates, insurance carrier).

Maps to [[project-truxon]] / Trux (the C-suite AI). Many metrics are computable from existing data (loads: rate/miles/empty_miles/times; invoices; fuel_transactions; toll_transactions; maintenance_records; trucks; drivers; watchdog uptime) — e.g. rev/mile, cost/mile, empty %, utilization, on-time %, customer concentration/profitability, fuel MPG (fuel_efficiency built), maintenance CPM, DSO/AR, invoice cycle time. Genuine DATA GAPS Truxon doesn't yet capture: safety/CSA/HOS/accidents, telematics idle/harsh events, budgets (budget-vs-actual), bids/pipeline/win-rate, driver turnover/NPS detail, insurance loss ratio, detention hours. Trux must say "not captured yet" for those, never fabricate.

**How to apply:** teach Trux the playbook framework + definitions; build tested scorecard RPCs for the computable metrics; point the Sentinel ([[project-truxon]] trux_insights) at the playbook's red-flag thresholds; treat the gaps as the instrumentation roadmap.
