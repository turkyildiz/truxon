-- R3 #6: booked vs actual per-load math on controlled seeds (fuel cpm is 0
-- with no fuel data locally, so pay/tolls/eld-miles carry the assertions —
-- the fuel terms share one code path with the cpm multiplier).
begin;
create extension if not exists pgtap with schema extensions;
select plan(5);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000f7f'::uuid, 'la@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000f7f';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000f7f"}', true);

insert into public.customers (company_name) values ('Actuals Broker');
insert into public.trucks (unit_number, status) values ('LA1', 'available');
insert into public.drivers (full_name, license_number, pay_per_mile, status)
values ('Pay Driver', 'LA-DL-1', 0.60, 'active');

insert into public.loads (load_number, customer_id, status, pickup_time, delivery_time,
                          rate, miles, truck_id, driver_id)
select 'LA-1', c.id, 'completed', now() - interval '3 days', now() - interval '1 day',
       3000, 1000, t.id, d.id
  from public.customers c, public.trucks t, public.drivers d
 where c.company_name = 'Actuals Broker' and t.unit_number = 'LA1' and d.full_name = 'Pay Driver';

-- truck actually drove 1100 banked ELD miles in the window (deadhead included)
insert into public.eld_daily_miles (day, truck_id, state, miles, points)
select (now() - interval '2 days')::date + n, (select id from public.trucks where unit_number = 'LA1'),
       'OH', case n when 0 then 600 else 500 end, 100
  from generate_series(0, 1) n;

insert into public.toll_transactions (toll_id, truck_id, exit_date_time, toll_charge)
values ('LA-TOLL-1', (select id from public.trucks where unit_number = 'LA1'),
        now() - interval '2 days', 40);

select is((select a.driver_pay from public.load_actuals(30) a where a.load_number = 'LA-1'),
  600.00::numeric, 'driver pay = 1000 mi x $0.60');
select is((select a.eld_miles from public.load_actuals(30) a where a.load_number = 'LA-1'),
  1100::numeric, 'banked ELD miles cover the window');
select is((select a.tolls from public.load_actuals(30) a where a.load_number = 'LA-1'),
  40::numeric, 'transponder tolls inside the window attach');
select is((select a.actual_margin from public.load_actuals(30) a where a.load_number = 'LA-1'),
  2360.00::numeric, 'actual margin = 3000 - 600 pay - 40 tolls (fuel cpm 0 locally)');

select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000f7a"}', true);
insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000f80'::uuid, 'la-drv@test.local');
update public.profiles set role = 'driver' where id = '00000000-0000-4000-8000-000000000f80';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000f80"}', true);
select throws_ok('select * from public.load_actuals(30)', 'P0001', 'Not enough permissions',
  'actuals are office-only');

select * from finish();
rollback;
