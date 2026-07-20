-- apply_load_geocode stamps stop coordinates even on a BILLED load (whose direct
-- updates are otherwise locked by loads_before_update). This is the exact case
-- the geocode backfill hit: most historical loads are billed.
begin;
create extension if not exists pgtap with schema extensions;
select plan(4);

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

select * from finish();
rollback;
