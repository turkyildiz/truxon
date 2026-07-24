-- R9 #34: the statement email draft is propose-only — it carries the recipient
-- (or flags it missing), a subject, and a body with the balances; it sends
-- nothing.
begin;
create extension if not exists pgtap with schema extensions;
select plan(5);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-0000000001a4'::uuid, 'se-acct@test.local');
update public.profiles set role = 'accountant' where id = '00000000-0000-4000-8000-0000000001a4';
insert into auth.users (id, email) values ('00000000-0000-4000-8000-0000000001a5'::uuid, 'se-drv@test.local');
update public.profiles set role = 'driver' where id = '00000000-0000-4000-8000-0000000001a5';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000001a4"}', true);

insert into public.customers (company_name, email) values ('SE Broker', 'ap@sebroker.test');
insert into public.invoices (invoice_number, customer_id, invoice_date, total, status)
select 'SE-1', id, '2026-06-10', 2500, 'sent' from public.customers where company_name='SE Broker';

create temp table d as select public.customer_statement_email_draft(
  (select id from public.customers where company_name='SE Broker'), '2026-06-01', '2026-06-30') as v;

select is((select v->>'to' from d), 'ap@sebroker.test', 'recipient taken from the customer email on file');
select ok((select (v->>'has_recipient')::boolean from d), 'has_recipient is true when an email exists');
select ok((select v->>'subject' like '%SE Broker%' from d), 'subject names the customer');
select ok((select v->>'body' like '%$2,500.00%' from d), 'body carries the billed/closing balance');

-- driver refused
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000001a5"}', true);
select throws_ok($$ select public.customer_statement_email_draft(1, '2026-06-01', '2026-06-30') $$,
  'Not enough permissions', 'driver cannot draft a statement email');

select * from finish();
rollback;
