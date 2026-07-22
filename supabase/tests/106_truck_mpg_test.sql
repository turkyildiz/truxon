-- truck_mpg(): per-truck MPG from ELD actual miles ÷ day-matched diesel
-- gallons (fuel only counts on days that truck banked GPS miles), and the
-- scorecard's fleet_mpg switching to the ELD basis when coverage exists.
begin;
create extension if not exists pgtap with schema extensions;
select plan(8);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000106'::uuid, 'mpg@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000106';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000106"}', true);

insert into public.trucks (unit_number) values ('MPG-1'), ('MPG-2'), ('MPG-3');

-- MPG-1: miles every day for a week; 200 diesel gal on covered days → 7.00
insert into public.eld_daily_miles (day, truck_id, state, miles, points, path)
select current_date - g, (select id from public.trucks where unit_number='MPG-1'), 'IL', 200, 10, '[]'::jsonb
from generate_series(1, 7) g;
insert into public.fuel_transactions (uuid, truck_id, transaction_time, gallons, amount, fuel_type, status)
values ('mpg1-a', (select id from public.trucks where unit_number='MPG-1'), now() - interval '5 days', 120, 420, 'Diesel', 'Approved'),
       ('mpg1-b', (select id from public.trucks where unit_number='MPG-1'), now() - interval '2 days',  80, 280, 'Diesel', 'Approved'),
       -- DEF must NOT count toward MPG gallons (real AtoB label)
       ('mpg1-c', (select id from public.trucks where unit_number='MPG-1'), now() - interval '2 days',  10,  30, 'Diesel Exhaust Fluid', 'Approved');

-- MPG-2: miles + 20 gal on a covered day → below the 30-gal floor, mpg null
insert into public.eld_daily_miles (day, truck_id, state, miles, points, path)
values (current_date - 3, (select id from public.trucks where unit_number='MPG-2'), 'IL', 500, 10, '[]'::jsonb);
insert into public.fuel_transactions (uuid, truck_id, transaction_time, gallons, amount, fuel_type, status)
values ('mpg2-a', (select id from public.trucks where unit_number='MPG-2'), now() - interval '3 days', 20, 70, 'Diesel', 'Approved');

-- MPG-3: the dead-ELD case — 100 gal on a day with NO banked miles. That fuel
-- must not manufacture an MPG (this is what dragged live fleet MPG to 4.02).
insert into public.eld_daily_miles (day, truck_id, state, miles, points, path)
values (current_date - 4, (select id from public.trucks where unit_number='MPG-3'), 'IL', 300, 10, '[]'::jsonb);
insert into public.fuel_transactions (uuid, truck_id, transaction_time, gallons, amount, fuel_type, status)
values ('mpg3-a', (select id from public.trucks where unit_number='MPG-3'), now() - interval '10 days', 100, 350, 'Diesel', 'Approved');

select is(
  (select t->>'mpg' from jsonb_array_elements(public.truck_mpg(30)->'trucks') t
    where t->>'unit_number' = 'MPG-1'),
  '7.00', 'MPG-1: 1400 ELD mi ÷ 200 tracked diesel gal = 7.00 (DEF excluded)');
select is(
  (select t->>'mpg' from jsonb_array_elements(public.truck_mpg(30)->'trucks') t
    where t->>'unit_number' = 'MPG-2'),
  null, 'MPG-2: under the 30-gal floor → mpg suppressed, not fabricated');
select is(
  (select t->>'mpg' from jsonb_array_elements(public.truck_mpg(30)->'trucks') t
    where t->>'unit_number' = 'MPG-3'),
  null, 'MPG-3: fuel on an untracked day is excluded → no fake MPG');
select is(
  (select t->>'gallons' from jsonb_array_elements(public.truck_mpg(30)->'trucks') t
    where t->>'unit_number' = 'MPG-3'),
  '100.0', 'MPG-3 raw gallons still visible (spend is real, ratio is not)');
select ok(
  (public.truck_mpg(30)->'fleet'->>'mpg')::numeric between 9.5 and 10.5,
  'fleet MPG pools miles ÷ tracked gallons only (2200 mi ÷ 220 gal = 10.00)');
select ok(
  jsonb_array_length(public.truck_mpg(30)->'weekly') >= 1,
  'weekly trend present');

-- scorecard basis: with ELD miles in-window the MPG denominator is day-matched
select is(
  public.company_scorecard(now() - interval '30 days', now())->'operations'->>'fleet_mpg_basis',
  'ELD actual miles ÷ day-matched diesel gallons',
  'scorecard fleet_mpg runs on the day-matched ELD basis when covered');

-- gate: drivers cannot read fleet economics (second admin first — the
-- last-active-admin guard refuses the demotion otherwise)
insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000107'::uuid, 'mpg2@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000107';
update public.profiles set role = 'driver' where id = '00000000-0000-4000-8000-000000000106';
select throws_ok(
  $$select public.truck_mpg(30)$$,
  'Not enough permissions',
  'driver role denied');

select * from finish();
rollback;
