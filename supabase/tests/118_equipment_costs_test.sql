-- Equipment costs: cleared form fields (null) no longer explode, and the
-- truck payment reaches the break-even without double-counting GL equipment.
begin;
create extension if not exists pgtap with schema extensions;
select plan(4);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000119'::uuid, 'eq@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000119';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000119"}', true);

-- 1) the exact save that used to 23502: null monthly_cost
insert into public.trucks (unit_number, monthly_cost, ownership, monthly_payment, purchase_price, purchase_date)
values ('EQ-1', null, 'financed', 2500, 165000, '2025-06-01');
select ok(
  (select monthly_cost is null from public.trucks where unit_number='EQ-1'),
  'cleared monthly_cost saves as null instead of erroring');

-- 2) ownership is constrained to real values
select throws_ok(
  $$ insert into public.trucks (unit_number, ownership) values ('EQ-BAD', 'borrowed') $$,
  23514, null, 'ownership check constraint rejects junk');

-- 3) component fallback (no GL rows in test db): payment joins fixed cost.
--    Seed a mileage base so per-mile math has a denominator.
insert into public.customers (company_name) values ('EQ Cust');
insert into public.drivers (full_name, status, pay_per_mile) values ('EQ Driver', 'active', 0.60);
insert into public.loads (customer_id, driver_id, truck_id, status, delivery_time, rate, miles, empty_miles)
select (select id from public.customers where company_name='EQ Cust'),
       (select id from public.drivers where full_name='EQ Driver'),
       (select id from public.trucks where unit_number='EQ-1'),
       'completed', now() - (g||' days')::interval, 2000, 950, 50
from generate_series(1, 28) g;

select ok(
  (public.fleet_cost_basis()->>'fixed_per_mile')::numeric > 0,
  'monthly_payment flows into fixed cost per mile (component basis)');
select ok(
  (public.fleet_cost_basis()->>'breakeven_rpm')::numeric
    > (public.fleet_cost_basis()->>'pay_per_mile')::numeric,
  'break-even sits above driver pay once equipment is counted');

select * from finish();
rollback;
