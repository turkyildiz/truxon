-- ops_service_metrics() (20260722009001): on-time pickup/delivery/combined +
-- missed rates from ELD arrival vs appointment. Seed one load with an on-time
-- pickup breadcrumb and a late delivery breadcrumb.
begin;
create extension if not exists pgtap with schema extensions;
select plan(6);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000993'::uuid, 'ops@test.local');
update public.profiles set role = 'dispatcher' where id = '00000000-0000-4000-8000-000000000993';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000993"}', true);

insert into public.customers (company_name) values ('Ops Broker');
insert into public.trucks (unit_number) values ('OPS-9');
-- pickup appointment 10 days ago @ 12:00; delivery 9 days ago @ 12:00
insert into public.loads (load_number, customer_id, truck_id, status, rate, miles,
                          pickup_lat, pickup_lon, pickup_time, delivery_lat, delivery_lon, delivery_time)
select 'OPS-L1', c.id, t.id, 'completed', 1500, 400,
       40.0, -80.0, now() - interval '10 days',
       41.0, -81.0, now() - interval '9 days'
  from public.customers c, public.trucks t
 where c.company_name = 'Ops Broker' and t.unit_number = 'OPS-9';

-- ELD: at pickup 1h BEFORE appointment (on-time); at delivery 3h AFTER (late)
insert into public.eld_location_history (id, truck_id, ts, lat, lng)
select gen_random_uuid(), t.id, now() - interval '10 days' - interval '1 hour', 40.0001, -80.0001 from public.trucks t where t.unit_number='OPS-9';
insert into public.eld_location_history (id, truck_id, ts, lat, lng)
select gen_random_uuid(), t.id, now() - interval '9 days' + interval '3 hours', 41.0001, -81.0001 from public.trucks t where t.unit_number='OPS-9';

select is((public.ops_service_metrics()->>'on_time_pickup_pct')::numeric, 100.0::numeric, 'pickup on-time = 100%');
select is((public.ops_service_metrics()->>'on_time_delivery_pct')::numeric, 0.0::numeric, 'delivery late = 0% on-time');
select is((public.ops_service_metrics()->>'on_time_service_pct')::numeric, 0.0::numeric, 'combined = 0% (delivery leg missed)');
select is((public.ops_service_metrics()->>'missed_pickup_pct')::numeric, 0.0::numeric, 'missed pickup = 0%');
select is((public.ops_service_metrics()->>'missed_delivery_pct')::numeric, 100.0::numeric, 'missed delivery = 100%');

select set_config('request.jwt.claims', null, true);
insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000994'::uuid, 'drv@test.local');
update public.profiles set role = 'driver' where id = '00000000-0000-4000-8000-000000000994';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000994"}', true);
select throws_ok('select public.ops_service_metrics()', 'P0001', 'Not enough permissions',
  'ops_service_metrics gated away from drivers');

select * from finish();
rollback;
