---
name: geocoding
description: Load stops geocoded to lat/lon+state for lane rate history (and later detention); LIVE except a Google Cloud key toggle
metadata:
  type: project
  originSessionId: a28d9126-d517-4423-90d2-26d2f9088c49
---

Loads carried only freeform `pickup_address` / `delivery_address` text (no structured state), which blocked lane-level analytics. Built & deployed 2026-07-20 (commits aedf08f + 0bff251) for [[northstar-project]].

**Pieces (all on prod):**
- `geocode_cache` table — one row per normalized address (`norm()` = lowercase, strip `.,#`, collapse ws), so a repeated shipper/receiver is never re-billed. Only ever holds a real result or a genuine `ZERO_RESULTS`.
- `loads.pickup_lat/lon/state`, `delivery_lat/lon/state`, `geocoded_at` — denormalized per load (fast lane grouping; later ELD-breadcrumb detention joins).
- `geocode` edge function (migration 20260720340001; cron/admin gated, `verify_jwt` default-true like eld-sync). Modes: `{address}` single, `{mode:'load',load_id}`, `{mode:'backfill',limit}`. Reuses **GOOGLE_MAPS_API_KEY** (same key the `distance` fn uses for Directions). **Transient failures (REQUEST_DENIED/quota/network) are NOT cached and do NOT stamp `geocoded_at`** → auto-heals next run.
- Hourly backfill cron `truxon-geocode-backfill` (`17 * * * *`, limit 60) — chews through history, then idles.
- `lane_rate_history(origin_state, dest_state)` RPC (trailing-180d avg/median $/mi on a lane) → Dispatch margin panel shows a `🛣️ Lane TX→CA has paid $X/mi` line beside the broker `customer_rate_profile` line. pgTAP 43.

**✅ LIVE & FULLY BACKFILLED (2026-07-20): all ~975 loads geocoded, `remaining: 0`.** Getting there took clearing three things:
1. Google `REQUEST_DENIED` — the Maps key's **API restrictions** listed only Directions API. Fixed in Google Cloud console (Credentials → Maps Platform API Key → API restrictions → added **Geocoding API**, kept Directions). Key id fcbc8115-…; project my-project-1470420386879.
2. `apply_load_geocode` RPC (migration 20260720350001) — direct `loads` UPDATEs of BILLED loads are rejected by `loads_before_update` ("Billed loads are locked") unless `app.load_rpc='1'`; most historical loads are billed, so the edge fn's direct `.update()` silently failed. The RPC sets the flag and writes only geocode metadata. Edge fn calls it (and checks the error → transient failures count as skipped/retry).
3. Double-booking guard (migration 20260720350002) — `loads_before_update` re-ran `assert_no_double_booking` on EVERY rpc update, so a metadata-only geocode write to an active load re-tripped it; 2 legacy in_transit loads have a double-booked driver (predates the guard). Now it re-checks only when driver/truck/status actually changes. **NB: reproduce the CURRENT loads_before_update body (cancelled-lock + customer_merge bypass, from 20260720140001) when touching this — I first clobbered it with an older copy and broke tests 01/27.**

Debug: `geocode` fn has `mode:'debug'` → returns stuck loads + the exact `stamp_error`. That's how #2/#3 were diagnosed.

Cost note: geocoding is billable (~$5/1000); the cache dedupes repeat shippers hard, so the full ~975-load sweep was cheap (mostly cache hits after the first pass). Also flagged: **2 loads (ids 2, 11) are in_transit with a double-booked driver** — likely stale demo data worth cleaning up.

Related: [[northstar-project]] (this unblocks per-lane margin now + detention detection later), [[project-truxon]].
