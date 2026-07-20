-- apply_load_geocode stamps stop coordinates even on a BILLED load (whose direct
-- updates are otherwise locked by loads_before_update). This is the exact case
-- the geocode backfill hit: most historical loads are billed.
begin;
create extension if not exists pgtap with schema extensions;
select plan(6);

insert into public.customers (company_name) values ('Geo Broker');
insert into public.loads (load_number, customer_id, status, delivery_time, rate, miles, pickup_address, delivery_address)
  select 'GEO-B', id, 'billed', now() - interval '5 days', 2000, 900, 'Dallas, TX', 'Los Angeles, CA'
    from public.customers where company_name = 'Geo Broker';

-- a direct update of a billed load is rejected by the guard...
select throws_ok(
  $$ update public.loads set pickup_state = 'TX' where load_number = 'GEO-B' $$,
  'Billed loads are locked; void the invoice first',
  'direct update of a billed load is blocked');

-- ...but the geocode RPC writes the metadata anyway
select public.apply_load_geocode(
  (select id from public.loads where load_number = 'GEO-B'),
  32.7767, -96.797, 'TX', 34.0522, -118.2437, 'CA');

select is((select pickup_state from public.loads where load_number = 'GEO-B'), 'TX', 'pickup state stamped on a billed load');
select is((select delivery_state from public.loads where load_number = 'GEO-B'), 'CA', 'delivery state stamped on a billed load');
select isnt((select geocoded_at from public.loads where load_number = 'GEO-B'), null, 'geocoded_at stamped');

-- A legacy double-booked state: two active loads share a driver (pre-dates the
-- double-booking guard). Seed it by bypassing triggers, then geocode one — a
-- metadata-only write must NOT re-trip the double-booking check.
insert into public.drivers (full_name, status) values ('Dbl Driver', 'active');
set session_replication_role = replica;
insert into public.loads (load_number, customer_id, status, delivery_time, rate, miles, driver_id, pickup_address, delivery_address)
  select 'DB-A', c.id, 'in_transit', now() - interval '1 day', 1500, 500, d.id, 'Erie, MI', 'Bridgeview, IL'
    from public.customers c, public.drivers d where c.company_name = 'Geo Broker' and d.full_name = 'Dbl Driver';
insert into public.loads (load_number, customer_id, status, delivery_time, rate, miles, driver_id, pickup_address, delivery_address)
  select 'DB-B', c.id, 'in_transit', now() - interval '1 day', 1600, 520, d.id, 'West Chester, OH', 'Alsip, IL'
    from public.customers c, public.drivers d where c.company_name = 'Geo Broker' and d.full_name = 'Dbl Driver';
set session_replication_role = origin;

select lives_ok(
  $$ select public.apply_load_geocode((select id from public.loads where load_number='DB-A'), 42.1, -80.1, 'MI', 41.7, -87.8, 'IL') $$,
  'metadata-only geocode succeeds on a double-booked active load');
select is((select pickup_state from public.loads where load_number = 'DB-A'), 'MI', 'double-booked active load gets geocoded');

select * from finish();
rollback;
