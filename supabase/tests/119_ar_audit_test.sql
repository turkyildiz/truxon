-- Audit regressions: factored invoices and their fee slivers stay out of AR
-- everywhere an owner reads a receivable number.
begin;
create extension if not exists pgtap with schema extensions;
select plan(5);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000120'::uuid, 'ar@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000120';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000120"}', true);

insert into public.customers (company_name) values ('AR Broker');

-- A: genuine open receivable, $1000, 50 days old -> counts everywhere
insert into public.invoices (invoice_number, customer_id, invoice_date, due_date, total, status, source)
values ('AR-OPEN', (select id from public.customers where company_name='AR Broker'),
        current_date - 50, current_date - 20, 1000, 'sent', 'truxon');
-- B: factored with a $60 fee sliver on the books -> counts NOWHERE as AR
insert into public.invoices (invoice_number, customer_id, invoice_date, due_date, total, status, source, qbo_balance, factored_at, factoring_fee, factor_name)
values ('AR-FACT', (select id from public.customers where company_name='AR Broker'),
        current_date - 50, current_date - 20, 1200, 'sent', 'qbo', 60, now() - interval '40 days', 60, 'Denim');

select is(
  (public.acct_summary()->>'ar_total')::numeric, 1000::numeric,
  'acct_summary AR excludes the factored sliver');
select is(
  (public.acct_summary()->>'factoring_reserve')::numeric, 0::numeric,
  'reserve is NET of fee: a pure fee sliver means nothing more is coming');
select is(
  (public.finance_extras()->>'ar_over_45')::numeric, 1000::numeric,
  'finance_extras aging bucket excludes factored');
select ok(
  (public.finance_march()->>'dso_days')::numeric is not distinct from
  (select round(1000.0 / nullif((select sum(total) from public.invoices where status <> 'void' and invoice_date >= current_date - 90),0) * 90, 1)),
  'DSO numerator excludes factored AR');
select is(
  (select (public.company_scorecard(now() - interval '90 days', now())->'financial'->>'ar_outstanding')::numeric),
  1000::numeric,
  'scorecard headline AR excludes factored');

select * from finish();
rollback;
