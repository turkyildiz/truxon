-- Weekly report: driver pay math (per-mile, plus empty miles only when the
-- driver's checkbox is on) and exclusion of cancelled/pending loads. Totals
-- are global to the DB, so assertions stay scoped to the seeded drivers.
begin;
create extension if not exists pgtap with schema extensions;
select plan(6);

-- ---------- seed ----------
insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000f03'::uuid, 'wk-admin@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000f03';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000f03"}', true);

insert into public.customers (company_name) values ('WK Test Broker');
insert into public.drivers (full_name, pay_per_mile, empty_miles_paid, pay_per_empty_mile)
  values ('WK Driver Plain', 0.60, false, 0.30),
         ('WK Driver Empty', 0.50, true, 0.30);
insert into public.trucks (unit_number) values ('WK-T1'), ('WK-T2');

-- Plain driver: 100 + 200 loaded miles, 50 empty miles that must NOT pay.
insert into public.loads (customer_id, rate, miles, empty_miles, notes)
  select id, 500, 100, 50, 'wk-p1' from public.customers where company_name = 'WK Test Broker';
insert into public.loads (customer_id, rate, miles, empty_miles, notes)
  select id, 700, 200, 0, 'wk-p2' from public.customers where company_name = 'WK Test Broker';
-- Empty-paid driver: 100 loaded + 40 empty miles that DO pay.
insert into public.loads (customer_id, rate, miles, empty_miles, notes)
  select id, 400, 100, 40, 'wk-e1' from public.customers where company_name = 'WK Test Broker';
-- Noise that must not count: a cancelled load and a pending load.
insert into public.loads (customer_id, rate, miles, empty_miles, notes)
  select id, 9999, 999, 99, 'wk-cancelled' from public.customers where company_name = 'WK Test Broker';
insert into public.loads (customer_id, rate, miles, notes)
  select id, 8888, 888, 'wk-pending' from public.customers where company_name = 'WK Test Broker';

select set_config('app.load_rpc', '1', true);
update public.loads set status = 'completed', delivery_time = now(),
       driver_id = (select id from public.drivers where full_name = 'WK Driver Plain'),
       truck_id  = (select id from public.trucks where unit_number = 'WK-T1')
 where notes in ('wk-p1', 'wk-p2');
update public.loads set status = 'completed', delivery_time = now(),
       driver_id = (select id from public.drivers where full_name = 'WK Driver Empty'),
       truck_id  = (select id from public.trucks where unit_number = 'WK-T2')
 where notes = 'wk-e1';
update public.loads set status = 'cancelled', delivery_time = now(),
       driver_id = (select id from public.drivers where full_name = 'WK Driver Plain'),
       truck_id  = (select id from public.trucks where unit_number = 'WK-T1')
 where notes = 'wk-cancelled';
update public.loads set delivery_time = now(),
       driver_id = (select id from public.drivers where full_name = 'WK Driver Plain')
 where notes = 'wk-pending';
select set_config('app.load_rpc', '', true);

-- ---------- assertions ----------
select is(
  (select (e->>'driver_pay')::numeric from jsonb_array_elements(public.weekly_report()->'by_driver') e
    where e->>'name' = 'WK Driver Plain'),
  180.00::numeric,
  'driver pay = loaded miles × rate (empty miles unpaid when disabled)'
);

select is(
  (select (e->>'revenue')::numeric from jsonb_array_elements(public.weekly_report()->'by_driver') e
    where e->>'name' = 'WK Driver Plain'),
  1200::numeric,
  'cancelled and pending loads do not count toward revenue'
);

select is(
  (select (e->>'loads')::int from jsonb_array_elements(public.weekly_report()->'by_driver') e
    where e->>'name' = 'WK Driver Plain'),
  2,
  'cancelled and pending loads do not count toward load count'
);

select is(
  (select (e->>'driver_pay')::numeric from jsonb_array_elements(public.weekly_report()->'by_driver') e
    where e->>'name' = 'WK Driver Empty'),
  62.00::numeric,
  'empty miles pay at the empty rate when enabled (100×0.50 + 40×0.30)'
);

select is(
  (select (e->>'avg_rate_per_mile')::numeric from jsonb_array_elements(public.weekly_report()->'by_driver') e
    where e->>'name' = 'WK Driver Plain'),
  4.00::numeric,
  'avg rate per mile = revenue / loaded miles'
);

select is(
  (select (e->>'miles')::numeric from jsonb_array_elements(public.weekly_report()->'by_truck') e
    where e->>'name' = 'WK-T1'),
  300::numeric,
  'truck miles exclude cancelled loads'
);

select * from finish();
rollback;
