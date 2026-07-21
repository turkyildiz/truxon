-- Sentinel data hygiene: stale in-transit loads, double-booked drivers and
-- doc-less delivered loads surface as findings; fixing the data auto-resolves.
begin;
create extension if not exists pgtap with schema extensions;
select plan(6);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000f58'::uuid, 'hyg@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000f58';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000f58"}', true);

insert into public.customers (company_name) values ('Hygiene Broker');
insert into public.drivers (full_name, status) values ('Stale Driver', 'active');

-- two active loads on the same driver, both with appointments 10 days back
-- (guard-violating legacy state — seeded with triggers off, like prod's #2/#11)
set session_replication_role = replica;
insert into public.loads (load_number, customer_id, driver_id, status, delivery_time, rate, miles)
select 'HYG-'||g, (select id from public.customers where company_name = 'Hygiene Broker'),
       (select id from public.drivers where full_name = 'Stale Driver'),
       'in_transit', now() - interval '10 days', 1500, 400
from generate_series(1, 2) g;
set session_replication_role = origin;

-- a delivered load 20 days old with no documents
insert into public.loads (load_number, customer_id, status, delivery_time, rate, miles)
values ('HYG-POD', (select id from public.customers where company_name = 'Hygiene Broker'),
        'delivered', now() - interval '20 days', 1800, 500);

select public.sentinel_scan();

select is(
  (select category from public.trux_insights
    where dedup_key = 'stale_transit:'||(select id from public.loads where load_number='HYG-1')),
  'data', 'a week-stale in-transit load fires a data finding');
select is(
  (select severity from public.trux_insights
    where dedup_key = 'double_booked:'||(select id from public.drivers where full_name='Stale Driver')),
  'critical', 'a double-booked driver is critical');
select ok(
  (select detail from public.trux_insights
    where dedup_key = 'double_booked:'||(select id from public.drivers where full_name='Stale Driver'))
    like '%HYG-1, HYG-2%', 'the finding names both loads');
select is(
  (select category from public.trux_insights
    where dedup_key = 'missing_pod:'||(select id from public.loads where load_number='HYG-POD')),
  'data', 'a doc-less delivered load fires a missing-POD finding');

-- close out one stale load → its finding resolves, double-booking resolves too
select set_config('app.load_rpc', '1', true);
update public.loads set status = 'delivered' where load_number = 'HYG-2';
select set_config('app.load_rpc', '', true);
select public.sentinel_scan();

select is(
  (select status from public.trux_insights
    where dedup_key = 'stale_transit:'||(select id from public.loads where load_number='HYG-2')),
  'resolved', 'closing the load resolves its stale-transit finding');
select is(
  (select status from public.trux_insights
    where dedup_key = 'double_booked:'||(select id from public.drivers where full_name='Stale Driver')),
  'resolved', 'one active load left → double-booking resolves');

select * from finish();
rollback;
