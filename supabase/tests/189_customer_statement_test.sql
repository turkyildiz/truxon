-- R9 #33: the customer statement carries an opening balance, in-period lines,
-- and a closing balance that ties out; drafts are excluded.
begin;
create extension if not exists pgtap with schema extensions;
select plan(6);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-0000000001a2'::uuid, 'cs-acct@test.local');
update public.profiles set role = 'accountant' where id = '00000000-0000-4000-8000-0000000001a2';
insert into auth.users (id, email) values ('00000000-0000-4000-8000-0000000001a3'::uuid, 'cs-drv@test.local');
update public.profiles set role = 'driver' where id = '00000000-0000-4000-8000-0000000001a3';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000001a2"}', true);

insert into public.customers (company_name) values ('CS Broker');

-- before the window: a sent (unpaid) invoice of 1000 → opening balance
insert into public.invoices (invoice_number, customer_id, invoice_date, total, status)
select 'CS-OPEN', id, '2026-05-15', 1000, 'sent' from public.customers where company_name='CS Broker';
-- in window (June): two sent invoices, and one draft that must NOT appear
insert into public.invoices (invoice_number, customer_id, invoice_date, total, status)
select 'CS-JUN-1', id, '2026-06-05', 2000, 'sent' from public.customers where company_name='CS Broker';
insert into public.invoices (invoice_number, customer_id, invoice_date, total, status)
select 'CS-JUN-2', id, '2026-06-20', 1500, 'paid' from public.customers where company_name='CS Broker';
insert into public.invoices (invoice_number, customer_id, invoice_date, total, status)
select 'CS-DRAFT', id, '2026-06-25', 999, 'draft' from public.customers where company_name='CS Broker';

create temp table s as select public.customer_statement(
  (select id from public.customers where company_name='CS Broker'), '2026-06-01', '2026-06-30') as v;

select is((select (v->>'opening_balance')::numeric from s), 1000.00, 'opening balance = pre-window unpaid');
select is((select jsonb_array_length(v->'lines') from s), 2, 'two in-period invoices listed (draft excluded)');
select is((select (v->>'billed_in_period')::numeric from s), 3500.00, 'billed in period sums the two sent/paid');
-- closing = opening 1000 + in-period balances (2000 sent unpaid + 0 paid) = 3000
select is((select (v->>'closing_balance')::numeric from s), 3000.00, 'closing balance ties opening + open in-period');
select ok((select v->'lines' @> '[{"invoice":"CS-DRAFT"}]'::jsonb from s) is not true,
  'the draft invoice never appears on the statement');

-- driver refused
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000001a3"}', true);
select throws_ok($$ select public.customer_statement(1, '2026-06-01', '2026-06-30') $$,
  'Not enough permissions', 'driver cannot pull a customer statement');

select * from finish();
rollback;
