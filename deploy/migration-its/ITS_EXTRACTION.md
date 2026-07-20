# ITS Dispatch extraction — reverse-engineered 2026-07-19

ITS Dispatch is a **Truckstop.com** product (T&C/privacy links → truckstop.com).
Legacy PHP shell (`app.itsdispatch.com/dispatch.php`) hosting modern JS editor
bundles. All endpoints are **session-cookie authed** — a `fetch(url,{credentials:'include'})`
from any `app.itsdispatch.com` page (i.e. run in the logged-in browser tab) works.

## Load list → editIds
- Dispatch board grid lives in iframe `#glu` → `/sections/dispatchboard_list.php`
  (search form: Load Number / Customer / Driver / Truck / **date From–To** =
  fields `search_from` / `search_to`, set via `set_calendar('glu', ...)`).
- Each result row's onclick: `showFrame_editload('<editId>', '0')`.
  **`<editId>` is exactly the `[ITS #<editId>]` marker we already store in
  `loads.notes`** — so the delta = board editIds whose id is NOT already in prod
  notes. (Confirmed sample editIds: 104767261, 104834031, 104838729, 104838975.)

## Per-load data (the goldmine)
`GET /modules/loads/data/edit_data.php?LoadEditID=<editId>` → ~800KB HTML: the
**fully-populated load editor**, 1,181 named inputs + 17 selects. (The sibling
`load_edit.script.php` is just the JS shell — don't parse that one.)

### Field map (verified names)
- Core: `load_number`, `work_order`, `bol_sequence`, `ltl_number`
- Customer: `customer_id` (select → option text is the broker name)
- Money: `total_rate`, `fsc`, `fsc_percent`, `other_charges`, `other_amount_1..6`,
  `total_practical_miles`, `empty_practical_miles`
- Equipment: `driver_id`, `truck_id`, `trailer_id`, `trailer_type`,
  `driver_internal_external`
- Carrier (if brokered out): `carrier_id`, `carrier_total_rate`, `carrier_fsc`, …
- Status: `status`
- Invoice flags: `on_invoice1..6`
- **Stops** — shipper (pickup) = `sh_*`, consignee (delivery) = `co_*`, numbered
  1..N: `sh_date_N` (YYYY-MM-DD), `sh_hour_N`, `sh_minute_N`, `sh_N_show_time`
  (1=timed). PO numbers `sh_po_numbers_N` / `co_po_numbers_N`.

### ⚠ Open mapping work (do before trusting output)
- **Some values are JS-populated**, not in the raw `value=` attr (e.g. a probe
  saw `sh_date_1=2025-04-22` present but `load_number`/`customer_id` blank on a
  detached DOMParser). Either parse in the LIVE tab after render, or find the JS
  data object in the HTML (an `init={...}` / assignment carrying the load record)
  and read from that instead of input values.
- Shipper/consignee **name + address** field names not yet confirmed (not
  `sh_name`/`sh_address`; likely `sh_shipper`/`sh_shipper_id` select + address
  lines). Pull a real timed multi-stop load and enumerate all `sh_*`/`co_*`.
- Map ITS `status` values → `STATUS_MAP` in import.mjs.

## Target shape (what import.mjs consumes: `its_loads_full.json`)
Array of `{ meta:{loadNum, editId, invoiceNum, invoiceDate, listCustomer},
stops:[{t:'pu'|'del', name, loc, date, h, m, ap, po}], customer_name, driver,
truck, trailer, trailer_type, total_rate, total_miles, empty_miles, work_order,
status, notes }`. Importer is **idempotent** (skips load_numbers already in prod)
and auto-creates missing customers/drivers.

## Documents
Per-load files: the original `receiver.mjs` (localhost:8123) captured docs the
browser POSTed. Doc URLs hang off the load editor's attachments section
(enumerate `edit_data.php` for file/attachment hrefs) — TODO if delta loads
carry rate cons/PODs worth importing.

## Delta cutover runbook (draft)
1. In the logged-in ITS tab, search the board `search_from` = last import date →
   collect all `showFrame_editload('<id>')` editIds.
2. Filter to ids NOT in prod `loads.notes` (`[ITS #<id>]`).
3. For each: fetch `edit_data.php`, parse → JSON row.
4. Write `its_loads_full.json`, run `node import.mjs <admin> <pw>` (idempotent).
5. Alias truck `003`→`03` first (AtoB name) or it punchlists.
