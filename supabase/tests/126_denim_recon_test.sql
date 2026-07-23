-- Denim reconciliation: fee mismatches surface, unmatched jobs surface, and
-- "we call it factored but Denim has no job" is counted.
begin;
create extension if not exists pgtap with schema extensions;
select plan(4);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000127'::uuid, 'dn@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000127';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000127"}', true);

insert into public.customers (company_name) values ('DN Broker');
insert into public.invoices (invoice_number, customer_id, invoice_date, due_date, total, status, source, factored_at, factoring_fee, factor_name)
values ('DN-MATCH', (select id from public.customers where company_name='DN Broker'),
        current_date - 30, current_date - 5, 1000, 'sent', 'qbo', now(), 25, 'Denim'),
       ('DN-GHOST', (select id from public.customers where company_name='DN Broker'),
        current_date - 30, current_date - 5, 900, 'sent', 'qbo', now(), 20, 'Denim');

-- Denim says the fee on DN-MATCH is 30, not the 25 on our books
insert into public.denim_jobs (denim_job_id, reference_number, fee, receivable, invoice_id)
values ('dj-1', 'DN-MATCH', 30, 1000, (select id from public.invoices where invoice_number='DN-MATCH')),
       ('dj-2', 'DN-ORPHAN', 15, 500, null);

select ok((public.denim_reconciliation()->'fee_mismatches')::text like '%DN-MATCH%',
  'fee disagreement with Denim surfaces');
select ok((public.denim_reconciliation()->'unmatched_jobs')::text like '%DN-ORPHAN%',
  'Denim job with no invoice surfaces');
select ok((public.denim_reconciliation()->>'factored_without_job')::int >= 1,
  'invoice we call factored but Denim never saw is counted');
select ok((public.denim_reconciliation()->>'denim_fees_total')::numeric = 45,
  'Denim-side fee total sums the mirror');

select * from finish();
rollback;
