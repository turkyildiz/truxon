-- Load margin: fleet_cost_basis derives MPG, fuel price, pay, fixed, breakeven
-- from recent data so dispatch can price a load before booking it.
begin;
create extension if not exists pgtap with schema extensions;
select plan(5);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-0000000000fb'::uuid, 'lm@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-0000000000fb';
insert into public.customers (company_name) values ('LM Broker');
insert into public.drivers (full_name, status, pay_per_mile) values ('LM Driver', 'active', 0.60);
insert into public.trucks (unit_number, status, monthly_cost) values ('LM1', 'available', 2600);

-- recent freight: 10,000 loaded miles
insert into public.loads (load_number, customer_id, driver_id, status, delivery_time, rate, miles, empty_miles)
  select 'LM-'||g, (select id from public.customers where company_name='LM Broker'),
         (select id from public.drivers where full_name='LM Driver'),
         'billed', (now() - (g||' days')::interval), 2500, 1000, 100
  from generate_series(1,10) g;

-- fuel: ~1,540 gallons (→ ~6.5 mpg on 10,000 mi) at ~$4/gal
insert into public.fuel_transactions (uuid, transaction_time, gallons, amount, status)
  select 'F-'||g, now() - (g||' days')::interval, 154, 616, 'Approved' from generate_series(1,10) g;

select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000000fb"}', true);

select cmp_ok((public.fleet_cost_basis()->>'mpg')::numeric, '>', 5::numeric, 'MPG derived from loaded miles ÷ gallons');
select cmp_ok((public.fleet_cost_basis()->>'fuel_price')::numeric, '>', 3::numeric, 'fuel price per gallon derived');
select is((public.fleet_cost_basis()->>'pay_per_mile')::numeric, 0.600::numeric, 'driver pay per mile picked up');
select cmp_ok((public.fleet_cost_basis()->>'fixed_per_mile')::numeric, '>', 0::numeric, 'fixed cost per mile from truck monthly cost');
select cmp_ok((public.fleet_cost_basis()->>'breakeven_rpm')::numeric, '>', 0.60::numeric, 'breakeven rate/mile exceeds bare driver pay');

select * from finish();
rollback;
