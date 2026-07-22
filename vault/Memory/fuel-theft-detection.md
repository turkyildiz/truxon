---
name: fuel-theft-detection
description: "Forest's fuel-theft Sentinel checks + fuel_efficiency_by_truck RPC; why MPG needs telematics"
metadata: 
  node_type: memory
  type: project
  originSessionId: a28d9126-d517-4423-90d2-26d2f9088c49
---

Built 2026-07-21 (migration 20260721230001, commit 64aacf0) after the owner asked
why Forest never flagged a truck's fuel. Root cause: Sentinel had NO fuel-theft or
efficiency check — only revenue-vs-fuel-*cost*. Fuel *theft* has transaction
signatures, not an MPG number.

**Added to `sentinel_scan()` (category 'money'):**
- `fuel_product` (critical): non-diesel fuel (unleaded/ethanol regex on fuel_type)
  on a diesel truck's card — it can't burn it. LIVE hits: truck 16 ~$2,980 unleaded,
  07 ~$1,286 E85, 15 $500 ethanol.
- `fuel_cash`: cash-advance / non-fuel (gallons=0, amount>0) charges >= $500/30d;
  critical >= $2,000. LIVE: 11 trucks, truck 08 $4,979 (> its diesel).
- `fuel_overflow` (critical): single fill > 200 gal.
- `fuel_recon` (Tier 2): miles = LOADED (loads.miles) + DEADHEAD (loads.empty_miles)
  vs gallons at 6.5 MPG; flags buying >=25% more than miles justify. Guarded
  >=2000 mi / >=100 gal so it's quiet until fuel capture is complete.
- **Dropped a rapid-refuel check** — on fuel-CARD data it fired almost entirely on
  ONE stop split into two lines (fill + top-off/DEF), i.e. noise not theft.

**`fuel_efficiency_by_truck(days=45)` RPC**: per-truck loaded/deadhead miles,
gallons, implied MPG, expected gal, variance %, non-diesel gallons, non-fuel spend.
Office-gated (admin/accountant/dispatcher; coalesce-hardened fail-closed on null).

**Data caveat (important):** absolute MPG is NOT trustworthy — odometer per fill is
sparse/garbage and fuel-card capture is partial (implied MPG comes out 36–163). So
`fuel_recon` only fires in the theft direction (bought > expected) and stays quiet
otherwise. Real per-truck efficiency needs clean per-fill miles = the telematics
feed ([[eld-drivehos]] / Motive). Also `fuel_transactions.amount` includes DEF/fees/
cash, so $/gal is unreliable; use gallons + fuel_type, not amount, for consumption.

Verified live on prod: 15 real findings, 0 noise. 6 pgTAP (test 88). Related:
[[northstar-project]], [[security-posture]] (null-role gate class).
