-- load_route(): breadcrumbs inside the load window, ordered, downsampled.
begin;
create extension if not exists pgtap with schema extensions;
select plan(4);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000116'::uuid, 'rt@test.local');
update public.profiles set role = 'dispatcher' where id = '00000000-0000-4000-8000-000000000116';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000116"}', true);

insert into public.trucks (unit_number) values ('RT-1');
insert into public.customers (company_name) values ('RT Cust');
insert into public.drivers (full_name, status) values ('RT Driver', 'active');
insert into public.loads (customer_id, driver_id, truck_id, status, pickup_time, delivery_time, rate)
values ((select id from public.customers where company_name='RT Cust'),
        (select id from public.drivers where full_name='RT Driver'),
        (select id from public.trucks where unit_number='RT-1'),
        'completed', now() - interval '10 hours', now() - interval '2 hours', 1500);

-- 40 pings inside the window + 2 outside it (before pickup-2h, after delivery+4h)
insert into public.eld_location_history (id, vehicle_id, truck_id, vehicle_number, lat, lng, ts)
select gen_random_uuid(), gen_random_uuid(), (select id from public.trucks where unit_number='RT-1'), 'RT-1',
       41.8 + g * 0.01, -87.6 - g * 0.01, now() - interval '10 hours' + (g || ' minutes')::interval * 12
from generate_series(0, 39) g;
insert into public.eld_location_history (id, vehicle_id, truck_id, vehicle_number, lat, lng, ts)
values (gen_random_uuid(), gen_random_uuid(), (select id from public.trucks where unit_number='RT-1'), 'RT-1', 40.0, -90.0, now() - interval '14 hours'),
       (gen_random_uuid(), gen_random_uuid(), (select id from public.trucks where unit_number='RT-1'), 'RT-1', 40.0, -90.0, now() + interval '3 hours');

select is(
  (select (r->>'total_pings')::int from (select public.load_route(l.id) r from public.loads l
    where l.truck_id = (select id from public.trucks where unit_number='RT-1')) x),
  40, 'only pings inside the load window count');
select ok(
  (select jsonb_array_length(r->'points') between 30 and 40 from (select public.load_route(l.id) r from public.loads l
    where l.truck_id = (select id from public.trucks where unit_number='RT-1')) x),
  'points returned without silly downsampling at small counts');
select ok(
  (select (r->'points'->0->>0)::numeric = 41.8 from (select public.load_route(l.id) r from public.loads l
    where l.truck_id = (select id from public.trucks where unit_number='RT-1')) x),
  'ordered by time — first in-window ping comes first');
select is(
  (select r->>'reason' from (select public.load_route(999999999) r) x),
  'no truck or window', 'unknown load returns an empty, explained result');

select * from finish();
rollback;
