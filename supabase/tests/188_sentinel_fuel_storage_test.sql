-- R9 #80/#85: fuel-with-no-load and storage-growth sentinels fire on the
-- anomaly and auto-resolve when it clears.
begin;
create extension if not exists pgtap with schema extensions;
select plan(4);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-0000000001a1'::uuid, 'fs-admin@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-0000000001a1';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000001a1"}', true);

insert into public.customers (company_name) values ('FS Broker');
insert into public.trucks (unit_number) values ('FS-T');

-- #80: a fuel charge on FS-T two days ago, but its only load delivered a week+ ago
insert into public.loads (customer_id, rate, miles, status, truck_id, pickup_time, delivery_time)
select c.id, 1000, 400, 'completed', t.id, now() - interval '10 days', now() - interval '9 days'
  from public.customers c, public.trucks t where c.company_name='FS Broker' and t.unit_number='FS-T';
insert into public.fuel_transactions (uuid, truck_id, amount, gallons, transaction_time, status)
select 'FUEL-ORPHAN-1', t.id, 420, 100, now() - interval '2 days', 'Approved'
  from public.trucks t where t.unit_number='FS-T';

-- #85: a big pile of uploads this month vs a tiny trailing base
insert into public.customers (company_name) values ('FS Storage');
insert into public.documents (entity_type, entity_id, doc_type, filename, storage_path, size_bytes, uploaded_at)
select 'customer', (select id from public.customers where company_name='FS Storage'),
       'Other', 'big-'||g, 'test/big-'||g, 40 * 1048576, now()  -- 40MB each, this month
  from generate_series(1, 3) g;
-- a small trailing-months base (5MB two months ago)
insert into public.documents (entity_type, entity_id, doc_type, filename, storage_path, size_bytes, uploaded_at)
select 'customer', (select id from public.customers where company_name='FS Storage'),
       'Other', 'small', 'test/small', 5 * 1048576, date_trunc('month', now()) - interval '2 months' + interval '5 days';

select public.sentinel_scan();

-- 1-2. both fire
select is((select count(*) from public.trux_insights where dedup_key='fuel_orphan' and status<>'resolved'), 1::bigint,
  'fuel-with-no-load sentinel fired');
select is((select count(*) from public.trux_insights where dedup_key='storage_growth' and status<>'resolved'), 1::bigint,
  'storage-growth-anomaly sentinel fired');

-- 3. a load now covering the fuel time resolves #80
insert into public.loads (customer_id, rate, miles, status, truck_id, pickup_time, delivery_time)
select c.id, 1000, 400, 'completed', t.id, now() - interval '3 days', now() - interval '1 day'
  from public.customers c, public.trucks t where c.company_name='FS Broker' and t.unit_number='FS-T';
select public.sentinel_scan();
select is((select status from public.trux_insights where dedup_key='fuel_orphan'), 'resolved',
  'a load covering the fuel time clears the fuel-orphan finding');

-- 4. the fuel-orphan detail names the review location
select ok((select detail like '%Fuel page%' from public.trux_insights where dedup_key='fuel_orphan'),
  'the fuel finding points at where to review it');

select * from finish();
rollback;
