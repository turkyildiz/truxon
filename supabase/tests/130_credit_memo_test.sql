-- Credit-memo mirror: upsert is service-gated + idempotent; summary computes
-- the credit-memo rate against invoiced revenue.
begin;
create extension if not exists pgtap with schema extensions;
select plan(4);

-- upsert as service (no user)
select is(public.qbo_upsert_credit_memos(
  '[{"qbo_id":"cm1","doc_number":"CM-1","customer_qbo_id":"77","txn_date":"2026-06-15","total":200,"balance":0,"memo":"rate correction"}]'::jsonb),
  1, 'service upsert inserts');
select is(public.qbo_upsert_credit_memos(
  '[{"qbo_id":"cm1","doc_number":"CM-1","customer_qbo_id":"77","txn_date":"2026-06-15","total":250,"balance":0,"memo":"rate correction"}]'::jsonb),
  1, 'same id updates, no dup');

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000131'::uuid, 'cm@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000131';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000131"}', true);

insert into public.customers (company_name) values ('CM Broker');
insert into public.invoices (invoice_number, customer_id, invoice_date, due_date, total, status, source)
values ('CM-INV', (select id from public.customers where company_name='CM Broker'),
        date '2026-06-01', date '2026-07-01', 10000, 'paid', 'truxon');

select is((public.credit_memo_summary(12)->>'credit_memo_rate_pct')::numeric, 2.50::numeric,
  'rate = 250 / 10000');
select throws_ok(
  $$select public.qbo_upsert_credit_memos('[]'::jsonb)$$,
  null, 'Not enough permissions', 'upsert rejects signed-in users');

select * from finish();
rollback;
