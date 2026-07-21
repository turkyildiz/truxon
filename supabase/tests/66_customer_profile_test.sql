-- customer_profile: totals, monthly trend, pay behavior on outstanding balances.
begin;
create extension if not exists pgtap with schema extensions;
select plan(6);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000f66'::uuid, 'cp@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000f66';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000f66"}', true);

insert into public.customers (company_name) values ('Profile Broker');
insert into public.loads (load_number, customer_id, status, rate, miles, empty_miles, delivery_time)
values ('CP-1', (select id from public.customers where company_name = 'Profile Broker'),
        'completed', 5000, 2000, 0, now() - interval '20 days'),
       ('CP-2', (select id from public.customers where company_name = 'Profile Broker'),
        'completed', 3000, 1000, 0, now() - interval '50 days'),
       ('CP-OPEN', (select id from public.customers where company_name = 'Profile Broker'),
        'in_transit', 2000, 800, 0, null);
insert into public.invoices (customer_id, invoice_number, status, total, invoice_date, due_date)
values ((select id from public.customers where company_name = 'Profile Broker'),
        'CP-INV', 'sent', 5000, now() - interval '15 days', now() - interval '1 day');
select public.record_invoice_payment(
  (select id from public.invoices where invoice_number = 'CP-INV'), 2000::numeric,
  'ach', 'cp-part', now());

select ok(
  (public.customer_profile((select id from public.customers where company_name = 'Profile Broker'))->>'found')::boolean,
  'profile found');
select is(
  (public.customer_profile((select id from public.customers where company_name = 'Profile Broker'))->'totals'->>'loads_12m')::int,
  2, 'totals count completed loads only');
select is(
  (public.customer_profile((select id from public.customers where company_name = 'Profile Broker'))->'totals'->>'revenue_12m')::numeric,
  8000::numeric, '12-month revenue');
select is(
  (public.customer_profile((select id from public.customers where company_name = 'Profile Broker'))->'pay'->>'open_outstanding')::numeric,
  3000::numeric, 'open AR is the OUTSTANDING balance after partial payment');
select is(
  (public.customer_profile((select id from public.customers where company_name = 'Profile Broker'))->'activity'->>'open_loads')::int,
  1, 'in-transit load counted as open');
select is(
  (public.customer_profile(999999999)->>'found')::boolean,
  false, 'unknown customer returns found=false');

select * from finish();
rollback;
