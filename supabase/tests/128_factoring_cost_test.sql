-- Factoring cost summary: effective rate math and monthly buckets.
begin;
create extension if not exists pgtap with schema extensions;
select plan(3);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000129'::uuid, 'fc@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000129';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000129"}', true);

insert into public.customers (company_name) values ('FC Broker');
insert into public.invoices (invoice_number, customer_id, invoice_date, due_date, total, status, source, factored_at, factoring_fee, factor_name)
values ('FC-1', (select id from public.customers where company_name='FC Broker'),
        date '2026-05-10', date '2026-06-10', 2000, 'paid', 'qbo', now(), 60, 'Denim'),
       ('FC-2', (select id from public.customers where company_name='FC Broker'),
        date '2026-06-12', date '2026-07-12', 3000, 'paid', 'qbo', now(), 90, 'Denim');

select is((public.factoring_cost_summary()->>'effective_rate_pct')::numeric, 3.00::numeric,
  'effective rate = fees / face (150/5000 = 3%)');
select is(jsonb_array_length(public.factoring_cost_summary()->'months'), 2,
  'fees bucket by invoice month');
select is((public.factoring_cost_summary()->'months'->0->>'fees')::numeric, 60::numeric,
  'first month carries its own fees');

select * from finish();
rollback;
