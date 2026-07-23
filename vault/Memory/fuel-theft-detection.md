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

**REBUILT ON ELD GPS TRUTH 2026-07-23** (migrations 20260722020001–020004, the
telematics gap above is now closed): `fuel_efficiency_by_truck` miles basis =
**ELD GPS actuals** when the truck has breadcrumb coverage (`miles_basis='eld'`),
booked dispatch+deadhead fallback for dark trucks. Two hard-won correctness rules
(each caught on a live read before the sentinel spammed):
1. **Window-match**: the mileage bank starts 2026-06-29 — fuel summed over 45d vs
   ~23d of miles inflated every variance 30–300%.
2. **Day-match** (the real fix, same rule as `truck_mpg`): a gallon counts toward
   the ratio ONLY on days that truck banked GPS miles; off-day fuel is reported
   separately as `gallons_untracked` (dark ELD + full tank = its own red flag,
   owned by the `eld_dark` sentinel).
Calibration proof: well-tracked units read +2%/−7%; **unit 03 = +80% over with
FULL coverage and zero untracked gallons — a genuine anomaly**. Fuel page now has
a "Fuel vs. miles" ReconCard (same RPC, variance badges) so the owner sees why a
truck flagged. `fuel_recon` sentinel reads the shared function (one source of truth).

**Data caveat (softened but real):** fuel-card capture is still partial and
`fuel_transactions.amount` includes DEF/fees/cash — use gallons + fuel_type, not
amount, for consumption. The 6.5 MPG baseline vs. fleet's true ~6.4 tracked MPG
keeps variance honest at fleet level.

Verified live on prod: 15 real findings, 0 noise on v1; day-matched v2 verified
against live table. pgTAP tests 88 + 114. Related: [[northstar-project]],
[[eld-drivehos]], [[security-posture]] (null-role gate class).
