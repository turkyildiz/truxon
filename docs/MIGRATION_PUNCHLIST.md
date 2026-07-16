# ITS Dispatch → Truxon migration — punch list (2026-07-16)

Migrated live on 2026-07-16 evening with `deploy/migration-its/` tooling.
**Result: 203 customers, 27 drivers (11 active + 16 former), 12 trucks,
20 trailers, 983 loads (load #1 → #1150, originals preserved), and all
load documents** (rate cons, PODs, photos — see counts below).

## Needs a decision or fix — review together

1. **Apply the pending schema migration** `20260716180001_migration_fields.sql`
   (`supabase db push`) — adds driver phone/email/notes and truck/trailer
   plate fields — then run `deploy/migration-its/backfill_extras.mjs` to fill
   them from the ITS exports. Driver phones/emails/medical dates and
   equipment plate numbers are NOT in Truxon until this runs.
2. **Expose the new fields in the UI** (Drivers: phone/email/notes;
   Trucks/Trailers: plate number + expiry) once the migration is applied.
3. **Invoices were not recreated.** ITS invoice numbers and dates are kept on
   each load's Notes (e.g. "ITS invoice #1035 (2026-07-16)"), and the loads
   are `completed`, ready to re-bill from Truxon if desired. Recreating 971
   historical invoices with their original numbers would need a schema
   exception — decide: regenerate in Truxon (new numbers) vs. keep ITS as the
   billing archive for pre-migration loads.
4. **All 971 ITS invoices show UNPAID in ITS** ("Mark Paid" was never used),
   so receivables/aging could not be migrated meaningfully. If you track
   payments elsewhere (factoring statements?), we can backfill paid status.
5. **Multi-stop loads (123 of 983):** Truxon models one pickup + one delivery;
   intermediate stops were preserved in each load's Notes ("All stops: …").
   Proper multi-stop support is a future feature decision.
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
12. **Miles = ITS "total miles" (loaded+empty)**; empty miles preserved in
    load Notes. Rate-per-mile figures on old loads therefore use total miles.
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
