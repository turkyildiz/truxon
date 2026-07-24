-- R9 #77/#78: the two billing-hygiene sentinels fire on stuck money and
-- auto-resolve when the money moves.
begin;
create extension if not exists pgtap with schema extensions;
select plan(5);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-00000000019f'::uuid, 'sb-admin@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-00000000019f';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-00000000019f"}', true);

insert into public.customers (company_name) values ('SB Broker');

-- #77: a draft invoice older than 48h
insert into public.invoices (invoice_number, customer_id, total, status, created_at)
select 'SB-DRAFT-1', id, 1500, 'draft', now() - interval '3 days' from public.customers where company_name='SB Broker';

-- #78: a delivered load with a POD but no invoice, older than 72h
insert into public.loads (customer_id, rate, miles, status, delivery_time)
select id, 2000, 500, 'completed', now() - interval '4 days' from public.customers where company_name='SB Broker';
insert into public.documents (entity_type, entity_id, doc_type, filename, storage_path)
select 'load', l.id, 'POD', 'pod.pdf', 'test/sb-pod' from public.loads l
  where l.customer_id = (select id from public.customers where company_name='SB Broker');

-- run the scan as the admin (sentinel_scan internally calls weekly_report,
-- which requires admin/accountant/dispatcher — service_role alone is refused)
select public.sentinel_scan();

-- 1-2. both findings are open
select is((select count(*) from public.trux_insights where dedup_key = 'invoice_unsent' and status <> 'resolved'), 1::bigint,
  'the unsent-draft-invoice sentinel fired');
select is((select count(*) from public.trux_insights where dedup_key = 'pod_not_invoiced' and status <> 'resolved'), 1::bigint,
  'the POD-but-not-invoiced sentinel fired');

-- 3. the detail names the dollar amount for the draft
select ok((select detail like '%$1,500%' from public.trux_insights where dedup_key = 'invoice_unsent'),
  'the invoice finding quantifies the unbilled dollars');

-- 4. sending the draft clears #77 on the next scan (auto-resolve)
update public.invoices set status = 'sent', sent_at = now() where invoice_number = 'SB-DRAFT-1';
select public.sentinel_scan();
select is((select status from public.trux_insights where dedup_key = 'invoice_unsent'), 'resolved',
  'sending the invoice auto-resolves the finding');

-- 5. invoicing the load (via create_invoice, which owns invoice_id) clears #78
select public.create_invoice(
  (select id from public.customers where company_name='SB Broker'),
  array(select id from public.loads where customer_id = (select id from public.customers where company_name='SB Broker') and status='completed'));
select public.sentinel_scan();
select is((select status from public.trux_insights where dedup_key = 'pod_not_invoiced'), 'resolved',
  'invoicing the load auto-resolves the POD finding');

select * from finish();
rollback;
