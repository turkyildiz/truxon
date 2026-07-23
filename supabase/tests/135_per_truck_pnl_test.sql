-- Per-truck P&L: each unit's own ledger nets out; ROI only claims to exist
-- when a payment is entered.
begin;
create extension if not exists pgtap with schema extensions;
select plan(3);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000136'::uuid, 'tp@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000136';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000136"}', true);

insert into public.customers (company_name) values ('TP Broker');
insert into public.trucks (unit_number, monthly_payment) values ('TP-PAID', 1000), ('TP-FREE', null);
insert into public.drivers (full_name, status, pay_per_mile) values ('TP Driver', 'active', 0.5);
insert into public.loads (customer_id, rate, miles, status, delivery_time, truck_id, driver_id)
values ((select id from public.customers where company_name='TP Broker'), 5000, 1000, 'completed',
        date_trunc('month', now()) + interval '1 day',
        (select id from public.trucks where unit_number='TP-PAID'),
        (select id from public.drivers where full_name='TP Driver'));

-- revenue 5000 - driver pay 500 - payment 1000 (1 month) = net 3500
select is(
  (select (t->>'net')::numeric from jsonb_array_elements(public.per_truck_pnl(1)->'trucks') t
    where t->>'unit' = 'TP-PAID'),
  3500::numeric, 'net = revenue - driver pay - payment');
select is(
  (select (t->>'roi_x')::numeric from jsonb_array_elements(public.per_truck_pnl(1)->'trucks') t
    where t->>'unit' = 'TP-PAID'),
  4.5::numeric, 'ROI = contribution / payment (4500/1000)');
select ok(
  (select t->>'roi_x' is null from jsonb_array_elements(public.per_truck_pnl(1)->'trucks') t
    where t->>'unit' = 'TP-FREE'),
  'no payment entered -> no fake ROI');

select * from finish();
rollback;
