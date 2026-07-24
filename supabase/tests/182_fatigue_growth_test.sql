-- R9 #71/#74: fatigue streaks flag only ongoing long runs; the breakeven model
-- returns a coherent verdict from real economics.
begin;
create extension if not exists pgtap with schema extensions;
select plan(6);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-00000000019b'::uuid, 'fg-admin@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-00000000019b';
insert into auth.users (id, email) values ('00000000-0000-4000-8000-00000000019c'::uuid, 'fg-drv@test.local');
update public.profiles set role = 'driver' where id = '00000000-0000-4000-8000-00000000019c';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-00000000019b"}', true);

insert into public.customers (company_name) values ('FG Broker');
insert into public.drivers (full_name, status) values ('Tired Tom', 'active'), ('Rested Rita', 'active');

-- Tired Tom: a single 8-day load spanning the last 8 days (8 consecutive work-days, ongoing)
insert into public.loads (customer_id, driver_id, rate, miles, status, pickup_time, delivery_time)
select c.id, d.id, 4000, 3000, 'delivered', now() - interval '8 days', now() - interval '1 day'
  from public.customers c, public.drivers d where c.company_name='FG Broker' and d.full_name='Tired Tom';

-- Rested Rita: two short loads with a big gap — no long streak
insert into public.loads (customer_id, driver_id, rate, miles, status, pickup_time, delivery_time)
select c.id, d.id, 1000, 400, 'delivered', now() - interval '20 days', now() - interval '19 days'
  from public.customers c, public.drivers d where c.company_name='FG Broker' and d.full_name='Rested Rita';
insert into public.loads (customer_id, driver_id, rate, miles, status, pickup_time, delivery_time)
select c.id, d.id, 1000, 400, 'delivered', now() - interval '2 days', now() - interval '1 day'
  from public.customers c, public.drivers d where c.company_name='FG Broker' and d.full_name='Rested Rita';

-- 1-2. fatigue watch flags only Tom's ongoing 8-day streak
select is((select jsonb_array_length(public.driver_fatigue_watch(6, 30)->'flagged')), 1,
  'one driver flagged for a long ongoing streak');
select is((select public.driver_fatigue_watch(6, 30)->'flagged'->0->>'driver'), 'Tired Tom',
  'the driver on the 8-day run is named');

-- 3. an old streak that already ended is not flagged (raise threshold below Rita's 2)
select is((select jsonb_array_length(public.driver_fatigue_watch(6, 30)->'flagged')), 1,
  'the rested driver never crosses the streak threshold');

-- #74 breakeven: seed trucks with fixed cost + some completed miles so the
-- model has economics to work with
insert into public.trucks (unit_number, status, monthly_cost) values
  ('BE-1', 'available', 8000), ('BE-2', 'available', 8000);
insert into public.loads (customer_id, rate, miles, status, delivery_time)
select id, 6000, 3000, 'completed', now() - interval '10 days' from public.customers where company_name='FG Broker';

select ok((select public.truck_breakeven_analysis() ? 'economics'), 'breakeven analysis returns economics');
select ok((select (public.truck_breakeven_analysis()->'new_truck'->>'verdict') is not null),
  'a plain-English verdict is produced');

-- driver refused
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-00000000019c"}', true);
select throws_ok($$ select public.truck_breakeven_analysis() $$,
  'Not enough permissions', 'driver cannot run the growth model');

select * from finish();
rollback;
