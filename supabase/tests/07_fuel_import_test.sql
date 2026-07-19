-- Fuel import: UUID idempotency, pending→settled upsert, truck/driver matching,
-- and the IFTA / per-truck reporting aggregations.
begin;
create extension if not exists pgtap with schema extensions;
select plan(11);

-- ---------- seed ----------
insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000f07'::uuid, 'fuel-admin@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000f07';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000f07"}', true);

insert into public.trucks (unit_number, vin) values ('07', ''), ('10', '1FUJGLDR0LLAA1234');
insert into public.drivers (full_name) values ('Jackson Ronald Spencer');

-- ---------- first import: one pending fuel row (unit 07) + one for unit 10 by VIN ----------
select is(
  (public.import_fuel_transactions($$[
    {"uuid":"u-aaa","transaction_time":"2026-07-19T12:19:25Z","status":"Pending","card_last_four":"8723",
     "merchant":"RACETRAC","merchant_state":"TX","amount":500.00,"driver_name":"Jackson Ronald Spencer",
     "vehicle_name":"07","vin":"","raw":{}},
    {"uuid":"u-bbb","transaction_time":"2026-07-18T01:36:00Z","status":"Approved","card_last_four":"6260",
     "merchant":"MAVERIK","merchant_state":"UT","amount":500.00,"net_of_discount":494.68,"gallons":106.4,
     "vehicle_name":"999","vin":"1FUJGLDR0LLAA1234","raw":{}}
  ]$$::jsonb) ->> 'inserted')::int,
  2, 'first import inserts both rows'
);

select is(
  (select truck_id from public.fuel_transactions where uuid = 'u-aaa'),
  (select id from public.trucks where unit_number = '07'),
  'row matched to truck by Vehicle Name = unit number'
);
select is(
  (select truck_id from public.fuel_transactions where uuid = 'u-bbb'),
  (select id from public.trucks where unit_number = '10'),
  'row matched to truck by VIN even when vehicle_name does not match'
);
select is(
  (select driver_id from public.fuel_transactions where uuid = 'u-aaa'),
  (select id from public.drivers where full_name = 'Jackson Ronald Spencer'),
  'row matched to driver by name'
);
select ok(
  (select gallons is null from public.fuel_transactions where uuid = 'u-aaa'),
  'pending row has no gallons yet'
);

-- ---------- re-import the SAME uuid, now settled (gallons + net filled in) ----------
select is(
  public.import_fuel_transactions($$[
    {"uuid":"u-aaa","transaction_time":"2026-07-19T12:19:25Z","posted_date":"2026-07-20T02:00:00Z",
     "status":"Approved","card_last_four":"8723","merchant":"RACETRAC","merchant_state":"TX",
     "amount":500.00,"net_of_discount":495.00,"gallons":98.5,"fuel_type":"Diesel",
     "vehicle_name":"07","vin":"","raw":{}}
  ]$$::jsonb),
  jsonb_build_object('received',1,'inserted',0,'updated',1,'unmatched_trucks',0),
  'settling a pending uuid is an UPDATE, not a duplicate'
);
select is(
  (select count(*)::int from public.fuel_transactions),
  2, 'still only two rows after the re-import'
);
select is(
  (select gallons from public.fuel_transactions where uuid = 'u-aaa'),
  98.5::numeric, 'the settled gallons landed on the existing row'
);

-- ---------- an unmatched truck ----------
select is(
  (public.import_fuel_transactions($$[
    {"uuid":"u-ccc","transaction_time":"2026-07-19T09:00:00Z","status":"Approved","merchant":"PILOT",
     "merchant_state":"AZ","amount":300.00,"net_of_discount":300.00,"gallons":60.0,
     "vehicle_name":"77","vin":"","raw":{}}
  ]$$::jsonb) ->> 'unmatched_trucks')::int,
  1, 'a row for an unknown unit number is left unmatched (truck_id null)'
);

-- ---------- reporting ----------
select is(
  (select spend::numeric from public.fuel_by_truck('2026-07-01','2026-08-01')
    where unit_number = '07'),
  495.00::numeric,
  'fuel_by_truck uses net_of_discount when present'
);

-- IFTA: UT 106.4 + TX 98.5 + AZ 60.0, three jurisdictions with gallons.
select is(
  (select count(*)::int from public.fuel_ifta_summary('2026-07-01','2026-08-01')),
  3,
  'IFTA summary groups gallons by jurisdiction (state)'
);

select * from finish();
rollback;
