-- Harsh-event proxy: a 60->10 mph drop in 8s is banked as braking; gradual
-- slowing is not; the count reaches the driver's weekly scorecard.
begin;
create extension if not exists pgtap with schema extensions;
select plan(3);

insert into public.trucks (unit_number) values ('HB-T');
insert into public.eld_vehicles (vehicle_id, number, truck_id, active)
values ('00000000-0000-4000-9000-000000000002'::uuid, 'HB-T',
        (select id from public.trucks where unit_number='HB-T'), true);

-- hard stop: 60 mph -> 10 mph in 8 seconds (yesterday)
insert into public.eld_location_history (id, vehicle_id, truck_id, lat, lng, speed, ts) values
  (gen_random_uuid(), '00000000-0000-4000-9000-000000000002'::uuid, (select id from public.trucks where unit_number='HB-T'), 40.0, -83.0, 60, (current_date - 1)::timestamptz + interval '10 hours'),
  (gen_random_uuid(), '00000000-0000-4000-9000-000000000002'::uuid, (select id from public.trucks where unit_number='HB-T'), 40.0, -83.0, 10, (current_date - 1)::timestamptz + interval '10 hours 8 seconds'),
-- gradual slowing: 60 -> 50 over 10s (no event)
  (gen_random_uuid(), '00000000-0000-4000-9000-000000000002'::uuid, (select id from public.trucks where unit_number='HB-T'), 40.1, -83.1, 60, (current_date - 1)::timestamptz + interval '11 hours'),
  (gen_random_uuid(), '00000000-0000-4000-9000-000000000002'::uuid, (select id from public.trucks where unit_number='HB-T'), 40.1, -83.1, 50, (current_date - 1)::timestamptz + interval '11 hours 10 seconds');

select is(public.detect_harsh_events(current_date - 1), 1, 'the hard stop is banked, gradual slowing is not');
select is((select kind from public.harsh_events where truck_id = (select id from public.trucks where unit_number='HB-T')),
  'braking', 'classified as braking');

-- scorecard wiring: driver ran that truck this week -> the count lands on their card
insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000139'::uuid, 'hb@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000139';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000139"}', true);
insert into public.customers (company_name) values ('HB Broker');
insert into public.drivers (full_name, status, pay_per_mile) values ('HB Driver', 'active', 0.5);
insert into public.loads (customer_id, rate, miles, status, delivery_time, truck_id, driver_id)
values ((select id from public.customers where company_name='HB Broker'), 1000, 400, 'completed',
        (current_date - 1)::timestamptz + interval '15 hours',
        (select id from public.trucks where unit_number='HB-T'),
        (select id from public.drivers where full_name='HB Driver'));
select is(
  (select (t->>'harsh_brakes')::int from jsonb_array_elements(
     public.driver_scorecard(case when extract(isodow from current_date) = 1 then 1 else 0 end)->'drivers') t
    where t->>'driver' = 'HB Driver'),
  1, 'harsh braking reaches the weekly scorecard');

select * from finish();
rollback;
