-- R9 #81/#82: the toll-orphan and duplicate-load sentinels fire on the anomaly
-- and auto-resolve when it clears.
begin;
create extension if not exists pgtap with schema extensions;
select plan(4);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-0000000001a0'::uuid, 'td-admin@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-0000000001a0';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000001a0"}', true);

insert into public.customers (company_name) values ('TD Broker');
insert into public.trucks (unit_number) values ('TD-T');

-- #81: a toll on TD-T yesterday, but the truck's only load delivered a week ago
insert into public.loads (customer_id, rate, miles, status, truck_id, pickup_time, delivery_time)
select c.id, 1000, 400, 'completed', t.id, now() - interval '9 days', now() - interval '8 days'
  from public.customers c, public.trucks t where c.company_name='TD Broker' and t.unit_number='TD-T';
insert into public.toll_transactions (toll_id, truck_id, toll_charge, post_date_time)
select 'TOLL-ORPHAN-1', t.id, 12.50, now() - interval '1 day' from public.trucks t where t.unit_number='TD-T';

-- #82: same customer + same lane entered twice today
insert into public.loads (customer_id, rate, miles, status, pickup_address, delivery_address, created_at)
select id, 1500, 500, 'pending', 'Shipper, Columbus OH', 'Receiver, Memphis TN', now()
  from public.customers where company_name='TD Broker';
insert into public.loads (customer_id, rate, miles, status, pickup_address, delivery_address, created_at)
select id, 1500, 500, 'pending', 'Shipper, Columbus OH', 'Receiver, Memphis TN', now()
  from public.customers where company_name='TD Broker';

select public.sentinel_scan();

-- 1-2. both fire
select is((select count(*) from public.trux_insights where dedup_key='toll_orphan' and status<>'resolved'), 1::bigint,
  'toll-with-no-load sentinel fired');
select is((select count(*) from public.trux_insights where dedup_key='duplicate_load' and status<>'resolved'), 1::bigint,
  'same-day duplicate-load sentinel fired');

-- 3. cancelling one duplicate (via cancel_load, which owns status) resolves #82
select public.cancel_load((select max(id) from public.loads where pickup_address='Shipper, Columbus OH'), 'duplicate');
select public.sentinel_scan();
select is((select status from public.trux_insights where dedup_key='duplicate_load'), 'resolved',
  'cancelling the phantom clears the duplicate finding');

-- 4. rematching the toll to a real in-window load resolves #81
insert into public.loads (customer_id, rate, miles, status, truck_id, pickup_time, delivery_time)
select c.id, 1000, 400, 'completed', t.id, now() - interval '2 days', now()
  from public.customers c, public.trucks t where c.company_name='TD Broker' and t.unit_number='TD-T';
select public.sentinel_scan();
select is((select status from public.trux_insights where dedup_key='toll_orphan'), 'resolved',
  'a load now covering the toll time clears the toll-orphan finding');

select * from finish();
rollback;
