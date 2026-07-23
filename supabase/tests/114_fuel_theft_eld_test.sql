-- fuel_efficiency_by_truck on the ELD basis: GPS miles beat booked miles when
-- present; a parked-idle diverter (fuel, no GPS miles) flags; an honest
-- out-of-route burner (GPS > booked) stops false-flagging.
begin;
create extension if not exists pgtap with schema extensions;
select plan(4);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000115'::uuid, 'ft@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000115';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000115"}', true);

insert into public.trucks (unit_number) values ('FTE-1'), ('FTE-2');
insert into public.customers (company_name) values ('FT Test Cust');
insert into public.drivers (full_name, status) values ('FT Driver', 'active');

-- FTE-1: booked only 2,000 mi but ELD shows 3,900 actual (lots of out-of-route);
-- bought 600 gal. Booked basis: expected 308 gal → 95% over → would FLAG.
-- ELD basis: expected 600 gal → 0% over → honest, must NOT flag.
insert into public.loads (customer_id, driver_id, truck_id, status, delivery_time, rate, miles, empty_miles)
values ((select id from public.customers where company_name='FT Test Cust'),
        (select id from public.drivers where full_name='FT Driver'),
        (select id from public.trucks where unit_number='FTE-1'),
        'completed', now() - interval '10 days', 4000, 1800, 200);
insert into public.eld_daily_miles (day, truck_id, state, miles, points, path)
select current_date - g, (select id from public.trucks where unit_number='FTE-1'), 'IL', 300, 10, '[]'::jsonb
from generate_series(1, 13) g;
insert into public.fuel_transactions (uuid, truck_id, transaction_time, gallons, amount, fuel_type)
select 'fte1-'||g, (select id from public.trucks where unit_number='FTE-1'),
       now() - (g||' days')::interval, 100, 350, 'Diesel'
from generate_series(1, 6) g;

-- FTE-2: ELD-covered but barely moved (2,050 GPS mi) while buying 600 gal
-- (expected ~315) → 90% over → must flag on the ELD basis.
insert into public.eld_daily_miles (day, truck_id, state, miles, points, path)
select current_date - g, (select id from public.trucks where unit_number='FTE-2'), 'IL', 205, 10, '[]'::jsonb
from generate_series(1, 10) g;
insert into public.fuel_transactions (uuid, truck_id, transaction_time, gallons, amount, fuel_type)
select 'fte2-'||g, (select id from public.trucks where unit_number='FTE-2'),
       now() - (g||' days')::interval, 100, 350, 'Diesel'
from generate_series(1, 6) g;

select is(
  (select fe.miles_basis from public.fuel_efficiency_by_truck(45) fe
    where fe.unit_number = 'FTE-1'), 'eld', 'ELD coverage wins the miles basis');
select ok(
  (select fe.total_miles between 3800 and 4000 from public.fuel_efficiency_by_truck(45) fe
    where fe.unit_number = 'FTE-1'), 'total miles are the GPS actuals, not booked');

select public.sentinel_scan();

select ok(not exists (
  select 1 from public.trux_insights
   where dedup_key = 'fuel_recon:' || (select id from public.trucks where unit_number='FTE-1')),
  'honest out-of-route burner no longer false-flags');
select ok(exists (
  select 1 from public.trux_insights
   where dedup_key = 'fuel_recon:' || (select id from public.trucks where unit_number='FTE-2')
     and status <> 'resolved'),
  'low-GPS-miles heavy-buyer flags on the ELD basis');

select * from finish();
rollback;
