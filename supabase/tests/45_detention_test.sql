-- Detention: ELD breadcrumbs parked near a stop past the free time surface as
-- billable detention; a short dwell does not; distance scoping excludes crumbs
-- that aren't at the stop.
begin;
create extension if not exists pgtap with schema extensions;
select plan(6);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000f45'::uuid, 'det@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000f45';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000f45"}', true);

insert into public.customers (company_name) values ('Detention Broker');
insert into public.trucks (unit_number, status) values ('DET1', 'available'), ('DET2', 'available');

-- Load A: delivered yesterday at (40.0, -80.0); truck sat there 4 hours.
insert into public.loads (load_number, customer_id, status, delivery_time, rate, miles, truck_id, delivery_lat, delivery_lon, delivery_state)
  select 'DET-A', c.id, 'billed', now() - interval '25 hours', 2000, 600, t.id, 40.0, -80.0, 'PA'
    from public.customers c, public.trucks t where c.company_name='Detention Broker' and t.unit_number='DET1';
-- Load B: same idea but the truck only sat 1 hour → under free time, no detention.
insert into public.loads (load_number, customer_id, status, delivery_time, rate, miles, truck_id, delivery_lat, delivery_lon, delivery_state)
  select 'DET-B', c.id, 'billed', now() - interval '25 hours', 2000, 600, t.id, 41.0, -75.0, 'NJ'
    from public.customers c, public.trucks t where c.company_name='Detention Broker' and t.unit_number='DET2';

-- Breadcrumbs for DET1 at the stop, spanning 4 hours (arrival → departure).
insert into public.eld_location_history (id, truck_id, lat, lng, ts)
  select ('00000000-0000-4000-8000-0000000000' || lpad(g::text,2,'0'))::uuid,
         (select id from public.trucks where unit_number='DET1'),
         40.0, -80.0, now() - interval '25 hours' + make_interval(mins => g*60)
  from generate_series(0,4) g;
-- A far-away crumb inside the time window that must be excluded by distance.
insert into public.eld_location_history (id, truck_id, lat, lng, ts)
  values ('00000000-0000-4000-8000-0000000000ff'::uuid,
          (select id from public.trucks where unit_number='DET1'), 44.0, -84.0, now() - interval '24 hours');

-- Breadcrumbs for DET2: only 1 hour at the stop.
insert into public.eld_location_history (id, truck_id, lat, lng, ts)
  select ('00000000-0000-4000-8000-0000000001' || lpad(g::text,2,'0'))::uuid,
         (select id from public.trucks where unit_number='DET2'),
         41.0, -75.0, now() - interval '25 hours' + make_interval(mins => g*30)
  from generate_series(0,2) g;

-- haversine sanity
select cmp_ok(public.trux_miles(40.0,-80.0,40.0,-80.0), '<', 0.01::numeric, 'trux_miles is ~0 for the same point');
select cmp_ok(public.trux_miles(40.0,-80.0,44.0,-84.0), '>', 100::numeric, 'trux_miles large for far points');

-- DET-A: 4h dwell − 2h free = 120 min detention, $100 at $50/h
select is((select detention_min from public.detention_events() where load_number='DET-A'), 120, 'detention = dwell minus free time');
select is((select est_pay from public.detention_events() where load_number='DET-A'), 100.00::numeric, 'estimated detention pay at $50/h');
select is((select stop_type from public.detention_events() where load_number='DET-A'), 'delivery', 'detention attributed to the delivery stop');

-- DET-B: only 1h at the stop → below free time → not a detention event
select is((select count(*)::int from public.detention_events() where load_number='DET-B'), 0, 'a dwell under the free time is not billable detention');

select * from finish();
rollback;
