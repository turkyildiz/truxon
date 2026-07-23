-- ETA risk: far truck + near appointment = late; close truck + slack = ok.
begin;
create extension if not exists pgtap with schema extensions;
select plan(2);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000143'::uuid, 'er@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000143';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000143"}', true);

insert into public.customers (company_name) values ('ER Broker');
insert into public.trucks (unit_number) values ('ER-FAR'), ('ER-NEAR');
insert into public.eld_vehicles (vehicle_id, number, truck_id, active) values
  ('00000000-0000-4000-9000-000000000004'::uuid, 'ER-FAR', (select id from public.trucks where unit_number='ER-FAR'), true),
  ('00000000-0000-4000-9000-000000000005'::uuid, 'ER-NEAR', (select id from public.trucks where unit_number='ER-NEAR'), true);
-- Columbus-ish positions; delivery in Chicago (~280 mi) vs 20 min away
insert into public.eld_vehicle_status (vehicle_id, lat, lon, ts) values
  ('00000000-0000-4000-9000-000000000004'::uuid, 39.96, -83.00, now()),
  ('00000000-0000-4000-9000-000000000005'::uuid, 41.80, -87.60, now());
insert into public.loads (customer_id, rate, miles, status, delivery_time, delivery_lat, delivery_lon, truck_id, load_number)
values ((select id from public.customers where company_name='ER Broker'), 2000, 350, 'in_transit',
        now() + interval '2 hours', 41.88, -87.63, (select id from public.trucks where unit_number='ER-FAR'), 'ER-1'),
       ((select id from public.customers where company_name='ER Broker'), 1000, 20, 'in_transit',
        now() + interval '5 hours', 41.88, -87.63, (select id from public.trucks where unit_number='ER-NEAR'), 'ER-2');

select is(
  (select t->>'risk' from jsonb_array_elements(public.load_eta_risk()->'loads') t where t->>'load_number'='ER-1'),
  'late', '280 miles with 2 hours = late');
select is(
  (select t->>'risk' from jsonb_array_elements(public.load_eta_risk()->'loads') t where t->>'load_number'='ER-2'),
  'ok', 'a few miles with 5 hours = ok');

select * from finish();
rollback;
