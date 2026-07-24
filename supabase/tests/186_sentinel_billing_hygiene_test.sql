-- R9 billing-hygiene sentinels (canonical keys). The unsent-draft and
-- POD-but-uninvoiced checks live as stale_drafts / pod_uninvoiced (pre-existing;
-- the R9 20260724000012 invoice_unsent/pod_not_invoiced were duplicates and
-- were removed in 20260724000014). This confirms the canonical pair fires and
-- that the duplicate keys are gone.
begin;
create extension if not exists pgtap with schema extensions;
select plan(4);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-00000000019f'::uuid, 'sb-admin@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-00000000019f';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-00000000019f"}', true);

insert into public.customers (company_name) values ('SB Broker');

-- a draft invoice older than 48h → stale_drafts
insert into public.invoices (invoice_number, customer_id, total, status, created_at)
select 'SB-DRAFT-1', id, 1500, 'draft', now() - interval '3 days' from public.customers where company_name='SB Broker';

-- a completed load with a POD but no invoice, older than 72h → pod_uninvoiced
insert into public.loads (customer_id, rate, miles, status, delivery_time)
select id, 2000, 500, 'completed', now() - interval '4 days' from public.customers where company_name='SB Broker';
insert into public.documents (entity_type, entity_id, doc_type, filename, storage_path)
select 'load', l.id, 'POD', 'pod.pdf', 'test/sb-pod' from public.loads l
  where l.customer_id = (select id from public.customers where company_name='SB Broker');

select public.sentinel_scan();

-- 1-2. the canonical pair fires
select is((select count(*) from public.trux_insights where dedup_key = 'stale_drafts' and status <> 'resolved'), 1::bigint,
  'stale_drafts (unsent draft invoices 48h+) fired');
select is((select count(*) from public.trux_insights where dedup_key = 'pod_uninvoiced' and status <> 'resolved'), 1::bigint,
  'pod_uninvoiced (POD on file, no invoice 72h+) fired');

-- 3. the duplicate keys I added are gone — the brief reports each issue ONCE
select is((select count(*) from public.trux_insights where dedup_key in ('invoice_unsent', 'pod_not_invoiced')), 0::bigint,
  'the removed duplicate billing sentinels no longer produce findings');

-- 4. sending the draft auto-resolves stale_drafts on the next scan
update public.invoices set status = 'sent', sent_at = now() where invoice_number = 'SB-DRAFT-1';
select public.sentinel_scan();
select is((select status from public.trux_insights where dedup_key = 'stale_drafts'), 'resolved',
  'sending the invoice auto-resolves stale_drafts');

select * from finish();
rollback;
