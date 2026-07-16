# ITS Dispatch → Truxon migration — punch list (2026-07-16)

Migrated live on 2026-07-16 evening with `deploy/migration-its/` tooling.
**Result: 203 customers, 27 drivers (11 active + 16 former), 12 trucks,
20 trailers, 983 loads (load #1 → #1150, originals preserved), and all
load documents** (rate cons, PODs, photos — see counts below).

## Needs a decision or fix — review together

1. ~~Apply the pending schema migration~~ **DONE 2026-07-16 evening** —
   migration applied and `backfill_extras.mjs` run: driver phones/emails/
   medical notes and all truck/trailer plates are in.
2. **Expose the new fields in the UI** (Drivers: phone/email/notes;
   Trucks/Trailers: plate number + expiry). Data is in the DB, forms don't
   show it yet.
3. **Invoicing → QuickBooks** (owner decision 2026-07-16): QuickBooks owns
   accounting. The claude.ai QuickBooks connector is linked to the
   "Aida Logistics LLC" QBO company and verified working. Plan:
   - Near term: generate the invoice PDF in Truxon, book it in QBO (manual
     or Claude-assisted via the connector).
   - Product feature: a `quickbooks-sync` edge function using Intuit OAuth
     (needs an Intuit developer app + client keys — owner action), a
     "Connect QuickBooks" button in Settings, and auto-creating the QBO
     invoice when a Truxon invoice is marked Sent. Design session tomorrow.
   - Historical ITS invoices stay archived in ITS/QBO; each migrated load's
     Notes carries its ITS invoice # and date.
4. **All 971 ITS invoices show UNPAID in ITS** ("Mark Paid" was never used).
   Real receivables live in QuickBooks — nothing to migrate here.
5. ~~Multi-stop loads~~ **DONE 2026-07-16 evening** — `load_stops` table +
   "+ Add pickup/delivery location" editor on Dispatch and the load screen;
   full itineraries (2,115 stops incl. 51 multi-stop loads) backfilled from
   ITS; AI extraction now returns every stop; mileage sums all legs via
   Google waypoints.
6. **Street addresses on migrated loads are "Facility name, City, ST"** — ITS
   stores the full street address in its Shipper/Consignee address books,
   which don't export cleanly. If needed, we can scrape the shipper/consignee
   books and enrich the addresses by name.
7. **Customer file attachments not migrated** (the ITS customer-list file
   windows resisted automation). Load files all came over. If customers have
   contracts/setup packets attached in ITS, we'll grab them in a second pass.
8. **Two ITS customers were merged as duplicates** (same name, punctuation
   differences): "J Boren & Son's Logistics" / "J. Boren & Son's Logistics"
   and "RDS Logistics Inc." / "RDS LOGISTICS, INC.". Verify no loads were
   pointing at the "wrong" duplicate.
9. **ITS "Customer ID" column contains garbage** (emails/addresses typed into
   the wrong field). Ignored during import; clean up in ITS not needed —
   just don't trust that column if exporting again.
10. **16 former drivers** (marked "(Inactive)" in ITS) exist on historical
    loads but have no license/pay data — created as inactive drivers with
    names only. Fill in details if any of them return.
11. **Driver pay on historical loads:** driver pay is recomputed by Truxon
    weekly reports from `pay_per_mile × miles`. ITS pay history was NOT
    migrated — decide whether historic weekly reports need to match ITS
    driver settlements before relying on them retroactively.
12. **Miles = ITS "total miles" (loaded+empty)** on migrated loads (new
    loads get Google route miles + empty miles entered separately). Since
    driver pay now adds empty-miles × empty-rate on top, weekly reports for
    PRE-migration weeks can overstate pay vs. what ITS settled (empties
    counted in both terms). Fine going forward; just don't re-settle old
    weeks from Truxon without checking.
13. **Extraction QA:** 19/20 real rate cons extract correctly (incl. all 5
    scanned ones via vision). Known failure: Freight-Tec's columnar layout
    ("RateConfirmation (3).pdf") still returns prose instead of JSON.
14. **ITS subscription:** keep read-only access for a while as the archive
    (invoice PDFs, customer files) before cancelling.

## Verified working after migration

- Load 1136 spot-check: broker ref 941959, Prosponsive, driver Borum,
  truck 003, correct route/rate/miles/status.
- Dashboard live with real history (active loads, weekly revenue).
- Load numbers continue from LD-2026-#### for new loads; old numbers kept.
