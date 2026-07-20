-- Equipment enrichment: apply_equipment_enrichment fills only-blank fields off a
-- registration, never overwrites existing values (disagreements are logged as
-- conflicts), ignores non-allow-listed keys (unit_number), and logs provenance.
begin;
create extension if not exists pgtap with schema extensions;
select plan(11);

-- a truck with a known VIN but blank plate/expiry/make/model/year
insert into public.trucks (unit_number, vin, make, model, year, plate_number, plate_expiry)
  values ('EQ16', '1FUJGLDR0ABCDEF01', '', '', null, '', null);

-- service context (auth.uid() is null) — the RPC's required caller
select set_config('request.jwt.claims', '', true);

-- fill blanks from a "registration": new plate/expiry/make/model/year, plus a VIN
-- that MATCHES what's on file (no-op), and a unit_number that must be ignored.
select lives_ok($$
  select public.apply_equipment_enrichment(
    'truck',
    (select id from public.trucks where unit_number = 'EQ16'),
    jsonb_build_object(
      'vin', '1FUJGLDR0ABCDEF01',
      'plate_number', 'TX1234567',
      'plate_expiry', '2026-09-30',
      'make', 'Freightliner',
      'year', '2019',
      'unit_number', 'HACKED'
    ),
    null, 'test-model'
  )
$$, 'enrichment applies without error');

-- blanks got filled
select is((select plate_number from public.trucks where unit_number = 'EQ16'), 'TX1234567', 'blank plate_number filled');
select is((select plate_expiry from public.trucks where unit_number = 'EQ16'), '2026-09-30'::date, 'blank plate_expiry filled (typed date)');
select is((select make from public.trucks where unit_number = 'EQ16'), 'Freightliner', 'blank make filled');
select is((select year from public.trucks where unit_number = 'EQ16'), 2019, 'blank year filled (typed int)');

-- identity column is NEVER touched, even when present in the payload
select is((select unit_number from public.trucks where unit_number = 'EQ16'), 'EQ16', 'unit_number ignored (not allow-listed)');

-- a fill was logged; the matching VIN and the ignored unit_number were not
select is((select count(*)::int from public.equipment_enrichment_log where field = 'plate_number' and action = 'filled'), 1, 'fill logged with provenance');
select is((select count(*)::int from public.equipment_enrichment_log where field = 'unit_number'), 0, 'ignored key never logged');
select is((select count(*)::int from public.equipment_enrichment_log where field = 'vin'), 0, 'matching value is a no-op, not logged');

-- second document DISAGREES with the now-populated plate → conflict, not overwrite
select public.apply_equipment_enrichment(
  'truck',
  (select id from public.trucks where unit_number = 'EQ16'),
  jsonb_build_object('plate_number', 'CA9999999'),
  null, 'test-model'
);
select is((select plate_number from public.trucks where unit_number = 'EQ16'), 'TX1234567', 'existing value NOT overwritten by a disagreeing doc');
select is((select count(*)::int from public.equipment_enrichment_log where field = 'plate_number' and action = 'conflict'), 1, 'disagreement logged as a conflict');

select * from finish();
rollback;
