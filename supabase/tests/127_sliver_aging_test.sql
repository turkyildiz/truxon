-- Sliver aging sentinel: 90+ day-old invoices with fee residue nag once, in
-- aggregate — anchored on invoice_date (factored_at is all backfill-dated).
begin;
create extension if not exists pgtap with schema extensions;
select plan(2);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000128'::uuid, 'sa@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000128';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000128"}', true);

insert into public.customers (company_name) values ('SA Broker');
insert into public.invoices (invoice_number, customer_id, invoice_date, due_date, total, status, source, qbo_balance, factored_at, factoring_fee, factor_name)
values ('SA-OLD', (select id from public.customers where company_name='SA Broker'),
        current_date - 120, current_date - 90, 1200, 'sent', 'qbo', 45, now() - interval '2 days', 45, 'Denim');

select public.sentinel_scan();
select ok(exists (select 1 from public.trux_insights
  where dedup_key = 'sliver_aging' and severity = 'warn' and status <> 'resolved'
    and detail ilike '%Factoring tab%'), 'old sliver fires the aging nag');

-- clean the books -> the nag resolves itself
update public.invoices set qbo_balance = 0 where invoice_number = 'SA-OLD';
select public.sentinel_scan();
select ok(not exists (select 1 from public.trux_insights
  where dedup_key = 'sliver_aging' and status <> 'resolved'),
  'nag resolves when the books are clean');

select * from finish();
rollback;
