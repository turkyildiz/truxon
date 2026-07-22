---
name: eld-drivehos
description: "DriveHOS ELD partner API — telematics feed for Northstar (GPS, odometer, engine hours, HOS). LIVE: eld-sync running, 138K+ location rows, both keys set."
metadata: 
  node_type: memory
  type: reference
  originSessionId: a28d9126-d517-4423-90d2-26d2f9088c49
---

New data source (received 2026-07-20) for [[northstar-project]]: the **DriveHOS ELD partner API** — live truck telematics.

- **Base URL:** `https://api.drivehos.app/v2/` (NOT `/partner/v2` — that path 404s; `/partner/swagger/index.html` is just the docs UI, real spec at `/partner/swagger/doc.json`).
- **Auth:** every endpoint needs TWO headers — `X-API-Provider-Key` AND `X-API-Company-Key`. Response envelope: `{status_code, description, data}`.
- **Provider Key:** stored as Supabase secret `ELD_PROVIDER_KEY` (never in repo/memory). Provider key ALONE returns 401 — the per-company key is required.
- **BLOCKER:** need Aida's `X-API-Company-Key` before we can pull anything (no "list companies" endpoint). Asked Ilker for it.

**Endpoints (8, all GET):**
- `/v2/company-info` — carrier profile
- `/v2/drivers` (limit,page) · `/v2/driver/{id}` — driver roster
- `/v2/latest-driver-status` (driver_id,limit,page) — current HOS duty status / hours remaining
- `/v2/vehicles` (status,limit,page) · `/v2/vehicle/{id}` — vehicle roster (match to trucks by VIN/unit)
- `/v2/latest-vehicle-status` (vehicle_id,limit,page) — current odometer / engine hrs / location
- `/v2/vehicle-location-history/{vehicle_id}` (start_date,end_date,next_page_token,limit) — GPS breadcrumb trail — the gold for mileage + detention

**Auth CONFIRMED working** (2026-07-20): company key stored as secret `ELD_COMPANY_KEY`. company-info returns AIDA LOGISTICS LLC / DOT 4187601. Login user ike@aidalogistics.com password was shared in chat once — treat as exposed, use the API key not the password.

**Real field shapes (captured live):**
- `vehicles`: company_id, vehicle_id (uuid), number (unit — matches trucks, e.g. "003"→unit 3), vin, active
- `drivers`: company_id, driver_id (uuid), username, first_name, last_name, active
- `latest-vehicle-status`: + driver_id, **odometer**, fuel_level, speed, lat, lon, status (OFFLINE/IN_MOTION), timestamp, **calc_location** (human string, e.g. "1.5mi SE of Cicero, IL")
- `latest-driver-status`: break, drive, shift, cycle (**seconds remaining** on each HOS clock), current_status (DS_D=driving, etc.)
- `vehicle-location-history/{id}`: id, vehicle_number, vin, lat, **lng** (note: lng here vs lon in status), status, speed, timestamp, calc_location, direction (heading°). Paginated: response has `size` + `next_page_token`; **dates MUST be MM-DD-YYYY** (ISO/epoch → 400), limit max 1000.

**Match key:** ELD `vin` → trucks.vin (exact); fallback ELD `number` → trucks.unit_number (digit-normalized).

**What it feeds:** live fleet map (augments the flaky mobile GPS), accurate odometer → maintenance PM engine + IFTA state miles, load actual mileage / empty-mile detection, HOS-aware dispatch (who has hours), detention/dwell detection, breakdown prediction (Northstar #4). Next build: an `eld-sync` edge fn + tables (eld vehicles/drivers, live status, location breadcrumbs).
