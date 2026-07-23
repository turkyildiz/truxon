-- R9 sentinel batch: stale drafts, POD-but-uninvoiced, fuel/toll on
-- no-mileage days, duplicate load entries, QBO drift, 30d stale auto-close.
begin;
create extension if not exists pgtap with schema extensions;
select plan(7);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000138'::uuid, 'om@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000138';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000138"}', true);

insert into public.customers (company_name) values ('OM Broker');

-- #77 stale draft
insert into public.invoices (invoice_number, customer_id, invoice_date, due_date, total, status, source, created_at)
values ('OM-DRAFT', (select id from public.customers where company_name='OM Broker'),
        current_date - 5, current_date + 25, 1200, 'draft', 'truxon', now() - interval '3 days');

-- #78 POD on file, uninvoiced 72h+
insert into public.loads (customer_id, rate, miles, status, delivery_time)
values ((select id from public.customers where company_name='OM Broker'), 900, 400, 'completed', now() - interval '4 days');
insert into public.documents (entity_type, entity_id, doc_type, filename, storage_path, content_type, size_bytes)
values ('load', (select max(id) from public.loads), 'POD', 'pod.pdf', 'test/pod.pdf', 'application/pdf', 100);

-- #80/#81 fuel + toll on a day the ELD says the truck sat (ELD alive other days)
insert into public.trucks (unit_number) values ('OM-T');
insert into public.eld_daily_miles (day, truck_id, state, miles)
values (current_date - 3, (select id from public.trucks where unit_number='OM-T'), 'OH', 300);
insert into public.fuel_transactions (uuid, truck_id, transaction_time, amount, gallons)
values ('om-fuel-1', (select id from public.trucks where unit_number='OM-T'), now() - interval '1 day', 250, 60);
insert into public.toll_transactions (toll_id, truck_id, exit_date_time, toll_charge)
values ('om-toll-1', (select id from public.trucks where unit_number='OM-T'), now() - interval '1 day', 35);

-- #82 duplicate load entry
insert into public.loads (customer_id, rate, miles, status, pickup_time, pickup_address, delivery_address)
select (select id from public.customers where company_name='OM Broker'), 1500, 600, 'pending',
       now() - interval '1 day', '1 A St, Columbus OH', '2 B St, Chicago IL'
  from generate_series(1, 2);

-- #84 QBO drift
update public.qbo_sync_state set last_error = 'token refresh failed', last_pull_at = now() where id = 1;

-- #88 stale open finding from another producer
insert into public.trux_insights (dedup_key, category, severity, title, detail, entity_type, status, last_seen)
values ('om_ancient', 'ops', 'info', 'old', 'old', '', 'open', now() - interval '40 days');

select public.sentinel_scan();

select ok(exists (select 1 from public.trux_insights where dedup_key='stale_drafts' and status<>'resolved'),
  'stale draft fires');
select ok(exists (select 1 from public.trux_insights where dedup_key='pod_uninvoiced' and status<>'resolved'),
  'POD-but-uninvoiced fires');
select ok(exists (select 1 from public.trux_insights where dedup_key like 'fuel_darkday:%' and status<>'resolved'),
  'fuel on a no-mileage day fires');
select ok(exists (select 1 from public.trux_insights where dedup_key like 'toll_notruck:%' and status<>'resolved'),
  'toll on a no-mileage day fires');
select ok(exists (select 1 from public.trux_insights where dedup_key like 'dup_load:%' and status<>'resolved'),
  'duplicate load entry fires');
select ok(exists (select 1 from public.trux_insights where dedup_key='qbo_sync_stale' and status<>'resolved'),
  'QBO sync error fires');
select ok((select status from public.trux_insights where dedup_key='om_ancient') = 'resolved',
  '30d-unseen open finding auto-closes');

select * from finish();
rollback;
