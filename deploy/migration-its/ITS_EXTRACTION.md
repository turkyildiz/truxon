# ITS Dispatch extraction — reverse-engineered & verified 2026-07-19

ITS Dispatch is a **Truckstop.com** product. Legacy PHP shell
(`app.itsdispatch.com/dispatch.php`) hosting a **cross-origin** editor/board
iframe. Everything below is done with plain `fetch(url, {credentials:'include'})`
from the logged-in `app.itsdispatch.com` origin (i.e. inside the tab, or inside
a Playwright page after login) — no UI driving, no cross-origin walls.

> **⚠ Correction to the first draft:** the earlier note claimed per-load data
> lived at `edit_data.php?LoadEditID=<id>`. **That is wrong** — `LoadEditID=`
> returns a *blank editor template*, identical for every id (all four probes came
> back byte-identical with a placeholder `sh_date_1=2025-04-22`). The real data
> endpoint keys off **`id=`**, not `LoadEditID=`. Verified against live loads.

## 1. Enumerate loads → editIds  (POST, not GET)
`POST /sections/dispatchboard_list.php` — form `frmAppLogin`'s sibling
`dispatch_search` (method=post). Body fields:
```
searchinput= &search_filter=anything &search_from=YYYY-MM-DD &search_to=YYYY-MM-DD
&show_time=1 &open_closed=open|closed
```
Response HTML carries `showFrame_editload('<editId>', ...)` per row → regex out
the editIds. **`open_closed` is only honoured on POST** (GET query is ignored and
always returns the open board). Union `open` + `closed` to catch in-transit AND
recently-delivered loads. Once a load is invoiced it drops off the board — hence
nightly capture.

`search_filter` options (for targeted searches): `load_number`, `c.name`
(customer), `a.work_order`, `entryb.name` (shipper), `entryc.name` (consignee),
`sh_city`/`co_city`, `a.driver_id`, `a.truck_id`, …

## 2. Per-load full record  (the goldmine)
```
GET /modules/loads/data/edit_data.php
    ?window_id=0&duplicate=0&id=<editId>&dispatch_status=open&pending=0&office_id=0
```
→ ~177 KB fully-populated editor HTML (session-cookie authed). `dispatch_status`
is **ignored** (open/closed/delivered/empty all return the same data) — safe to
hardcode `open`. `new_ltl_id` is **not** required.

**`editId` is the `[ITS #<editId>]` marker we already store in `loads.notes`** —
so the delta = board editIds whose id is NOT already in prod notes.

## 3. Parse (static `value=` attrs + display-id typeaheads)
Values live in the HTML's static `value=` attributes and in `<option selected>` —
readable with a plain `DOMParser`, no script execution. Verified field map:

| Field | Source | Note |
|---|---|---|
| load_number | `[name=load_number]`.value | e.g. `1136` |
| work_order | `[name=work_order]`.value | e.g. `941959` |
| customer name | `#customer_id_display`.value | `[name=customer_id]` is a numeric ITS id |
| total_rate | `[name=total_rate]`.value | `1000.00` |
| miles | `[name=total_practical_miles]` / `[name=empty_practical_miles]` | 293 / 139 |
| driver | `select[name=driver_id] option[selected]`.text | `Terrance Montrell Borum` |
| truck | `select[name=truck_id] option[selected]`.text | unit `003` (option *text*, not value) |
| trailer_type | `select[name=trailer_type] option[selected]`.text | `53' Van` |
| status | `select[name=status] option[selected]`.text | `Unloading` (matches STATUS_MAP keys) |

**Stops** — shipper `sh_*`, consignee `co_*`, numbered 1..N:
- name → **`#sh_id_N_display` / `#co_id_N_display`** (stable ids; the typeahead's
  `name=live_type_id_<random>` is NOT stable — use the id).
- location → `sh_location_N` / `co_location_N` ("City, ST").
- timing → `sh_date_N` (YYYY-MM-DD), `sh_hour_N`, `sh_minute_N`, `sh_am_N` (AM/PM),
  `sh_N_show_time` (1=timed). PO → `sh_po_numbers_N`. Also present:
  `sh_type_N`, `sh_quantity_N`, `sh_weight_N`, `sh_cargo_value_N`, `sh_notes_N`.

Iterate N=1..; a stop exists when `sh_id_N` OR `sh_location_N` OR the display id
has a value. **Validated live** against load 1136 (1 pu → 1 del) and load 1162
(1 pu → 2 dels: correct sequence, correct final destination Channahon).

## 4. Login — ⚠ behind Cloudflare Turnstile (blocks automation)
`POST /login.php` (form `#frmAppLogin`, two tabs: **Email Login** = default,
`#email`+`#password`; **Classic Login** = `#account_numberlgn` (Aida=**IL76053**)
+`#usernamelgn`). No Auth0/MFA — BUT the login page is wrapped in **Cloudflare
Turnstile** ("Just a moment… performing security verification"). A headless /
Playwright browser (even headed) gets stuck in the check forever — it detects
`navigator.webdriver` + CDP. **We do NOT bypass bot-detection.** Consequence:
**unattended login is impossible**; only a real, human-driven browser
authenticates. The data endpoints (§1–§2) are NOT Turnstile-gated — once a real
browser holds the session, the fetches work fine. So capture is **assisted**:
harvest through the live logged-in tab (the §3 parser as one `page.evaluate`),
then `merge-its.mjs` folds the result into `its_loads_full.json`.
`fetch-its.mjs` (headless Playwright) is kept for its parser/enumeration
reference and a possible future CDP-attach-to-real-Chrome, but its headless
login cannot clear Turnstile.

## 5. Target shape (what import.mjs consumes: `its_loads_full.json`)
Array of `{ meta:{loadNum, editId, invoiceNum, invoiceDate, listCustomer,
capturedAt}, customer_name, driver, truck, trailer, trailer_type, total_rate,
total_miles, empty_miles, work_order, status, notes,
stops:[{t:'pu'|'del', name, loc, date, h, m, ap, po}] }`. Importer is
**idempotent** (skips load_numbers already in prod), maps status via `STATUS_MAP`,
builds stop timestamps with AM/PM via `iso()`, auto-creates missing
customers/drivers, and stamps `[ITS #<editId>]` into notes.

## Assisted capture → cutover (the runbook, rebuilt 2026-07-23)
Nightly unattended capture is dead (Turnstile, §4). The working loop — all
tools live IN THIS DIRECTORY now (the old box's scratchpad copies were lost in
the machine swap; never keep migration tooling out of the repo):
1. **(optional) FLOOR**: `CRON_SECRET=… node its-dryrun.mjs` prints the highest
   editId already in prod — paste into `its-harvest.js` so the probe sweep knows
   where to stop. Without it the harvester falls back to a date-guarded walk.
2. **Harvest** (owner): open app.itsdispatch.com logged-in → DevTools console →
   paste ALL of `its-harvest.js` → it enumerates open+closed boards **and probes
   editId gaps** (recovers loads that were invoiced and left the board — this is
   why one comprehensive harvest can replace the lost nightly accumulation) →
   downloads `its-captured-<date>.json`.
3. **Merge**: `node merge-its.mjs ~/Downloads/its-captured-*.json` → accumulates
   into `its_loads_full.json` + dated snapshot. Never touches prod.
4. **Dry-run**: `CRON_SECRET=… node its-dryrun.mjs` — maps the capture against
   prod (new vs already-in; unmatched customers/drivers/trucks; zero-rate flags).
5. At cutover (~Aug 1): fix any flags in ITS, re-harvest (final sweep), then
   `ADMIN_EMAIL=… ADMIN_PASSWORD=… node import.mjs --delta` (loads-only,
   idempotent; the 003→03 truck alias is built in). Review `punchlist.json`.

## Documents (TODO, lower priority)
Per-load attachments (rate cons / PODs) hang off the load editor's attachments
section. `receiver.mjs`/`upload_docs.mjs` handle the doc side if delta loads
carry files worth importing — not wired into the nightly job yet.
