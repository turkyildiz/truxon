-- Broken promise-to-pay sentinel (20260722009003): a past promised_date on a
-- still-unpaid invoice fires a cash finding; a fresh future promise or payment
-- clears it.
begin;
create extension if not exists pgtap with schema extensions;
select plan(4);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-00000000c101'::uuid, 'col@test.local');
-- admin, not accountant: sentinel_scan is admin/service gated and the positive-form
-- gate (20260723001001) no longer lets a NULL auth.role() slip through under pgTAP
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-00000000c101';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-00000000c101"}', true);

insert into public.customers (company_name) values ('Promise Broker');
insert into public.invoices (invoice_number, customer_id, total, status, invoice_date)
select 'PROM-1', id, 1200, 'sent', current_date - 40 from public.customers where company_name = 'Promise Broker';

-- a FUTURE promise → nothing broken yet
insert into public.collection_notes (customer_id, invoice_id, note, promised_amount, promised_date, created_by)
select c.id, i.id, 'next week', 1200, current_date + 3, '00000000-0000-4000-8000-00000000c101'
  from public.customers c join public.invoices i on i.invoice_number = 'PROM-1' where c.company_name = 'Promise Broker';
select ok((select public.sentinel_scan() is not null), 'scan runs');
select ok(not exists(select 1 from public.trux_insights where dedup_key like 'broken_promise:%' and status = 'open'),
  'a future promise does not fire');

-- add a LATER note with a past promised date → broken
insert into public.collection_notes (customer_id, invoice_id, note, promised_amount, promised_date, created_by)
select c.id, i.id, 'by Friday', 1200, current_date - 5, '00000000-0000-4000-8000-00000000c101'
  from public.customers c join public.invoices i on i.invoice_number = 'PROM-1' where c.company_name = 'Promise Broker';
select public.sentinel_scan();
select ok(exists(select 1 from public.trux_insights where dedup_key like 'broken_promise:%' and status = 'open'),
  'latest promise past-due on an open invoice fires');

-- pay it → resolves
update public.invoices set status = 'paid', paid_at = now() where invoice_number = 'PROM-1';
select public.sentinel_scan();
select is((select status from public.trux_insights where dedup_key like 'broken_promise:%'),
  'resolved', 'payment auto-resolves the broken-promise finding');

select * from finish();
rollback;
