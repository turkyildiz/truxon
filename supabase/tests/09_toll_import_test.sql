-- Toll import: tollId idempotency, truck match by vehicle number, violation
-- counting, and the by-truck / by-agency reporting.
begin;
create extension if not exists pgtap with schema extensions;
select plan(9);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000f09'::uuid, 'toll-admin@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000f09';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000f09"}', true);

insert into public.trucks (unit_number) values ('07'), ('10');

-- First import: two tolls (one a violation) for known trucks + one unknown truck.
select is(
  (public.import_toll_transactions($$[
    {"toll_id":"t-aaa","post_date_time":"2026-07-15T10:00:00Z","exit_date_time":"2026-07-14T22:00:00Z",
     "vehicle_number":"07","toll_agency_name":"NY Thruway","toll_agency_state":"NY",
     "toll_charge":12.50,"toll_category":"Normal","raw":{}},
    {"toll_id":"t-bbb","post_date_time":"2026-07-15T11:00:00Z","vehicle_number":"10",
     "toll_agency_name":"IL Tollway","toll_agency_state":"IL","toll_charge":45.00,"toll_category":"Violation","raw":{}},
    {"toll_id":"t-ccc","post_date_time":"2026-07-15T12:00:00Z","vehicle_number":"99",
     "toll_agency_name":"PA Turnpike","toll_agency_state":"PA","toll_charge":8.00,"toll_category":"Normal","raw":{}}
  ]$$::jsonb) ->> 'inserted')::int,
  3, 'first import inserts all three tolls'
);

select is(
  (select truck_id from public.toll_transactions where toll_id = 't-aaa'),
  (select id from public.trucks where unit_number = '07'),
  'toll matched to truck by vehicle number = unit number'
);
select is(
  (select truck_id from public.toll_transactions where toll_id = 't-ccc'),
  null::bigint, 'toll for an unknown unit number is left unmatched'
);
select is(
  (public.import_toll_transactions('[]'::jsonb) ->> 'violations')::int,
  1, 'violation count reflects the one Violation-category toll'
);

-- Re-import the same tollId with a corrected charge → UPDATE, not duplicate.
select is(
  public.import_toll_transactions($$[
    {"toll_id":"t-aaa","post_date_time":"2026-07-15T10:00:00Z","vehicle_number":"07",
     "toll_agency_state":"NY","toll_charge":10.00,"toll_category":"Normal","dispute_status":"Closed/Complete","raw":{}}
  ]$$::jsonb) -> 'updated',
  to_jsonb(1), 're-importing a tollId updates instead of duplicating'
);
select is(
  (select count(*)::int from public.toll_transactions),
  3, 'still three rows after re-import'
);
select is(
  (select toll_charge from public.toll_transactions where toll_id = 't-aaa'),
  10.00::numeric, 'the corrected charge landed on the existing row'
);

-- Reporting.
select is(
  (select spend::numeric from public.toll_by_truck('2026-07-01','2026-08-01') where unit_number = '10'),
  45.00::numeric, 'toll_by_truck sums the truck''s toll charges'
);
select is(
  (select count(*)::int from public.toll_by_agency('2026-07-01','2026-08-01')),
  3, 'toll_by_agency groups by jurisdiction/agency'
);

select * from finish();
rollback;
