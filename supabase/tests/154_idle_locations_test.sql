-- Idle heat-map: a 2h stationary stretch classifies by proximity to a load stop.
begin;
create extension if not exists pgtap with schema extensions;
select plan(2);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000154'::uuid, 'il@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000154';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000154"}', true);

insert into public.customers (company_name) values ('IL Broker');
insert into public.trucks (unit_number) values ('IL-T');
-- a recent load delivered at (40.0, -83.0)
insert into public.loads (customer_id, rate, miles, status, delivery_time, delivery_lat, delivery_lon)
values ((select id from public.customers where company_name='IL Broker'), 1000, 400, 'completed',
        now() - interval '1 day', 40.0, -83.0);
-- 2h parked AT the dock, then 1h parked far away (truck stop), with moving pings between
insert into public.eld_location_history (id, vehicle_id, truck_id, lat, lng, speed, ts)
select gen_random_uuid(), '00000000-0000-4000-9000-000000000006'::uuid,
       (select id from public.trucks where unit_number='IL-T'),
       lat, lng, speed, now() - interval '1 day' + (n || ' minutes')::interval
from (values
  (40.0, -83.0, 0, 0), (40.0, -83.0, 0, 60), (40.0, -83.0, 0, 120),
  (40.5, -83.5, 55, 150),
  (41.0, -84.0, 0, 180), (41.0, -84.0, 0, 210), (41.0, -84.0, 0, 240)
) v(lat, lng, speed, n);

select ok((public.idle_locations(7)->>'dock_hours')::numeric >= 1.9,
  'the at-dock stretch lands in dock hours');
select ok((public.idle_locations(7)->>'elsewhere_hours')::numeric between 0.9 and 1.5,
  'the far stretch lands elsewhere');

select * from finish();
rollback;
