-- replace_load_stops: atomicity (a bad row must leave the old itinerary
-- intact), seq renumbering per stop type, and the billed/cancelled locks.
begin;
create extension if not exists pgtap with schema extensions;
select plan(6);

-- ---------- seed ----------
insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000f05'::uuid, 'st-admin@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000f05';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000f05"}', true);

insert into public.customers (company_name) values ('ST Test Broker');
insert into public.loads (customer_id, rate, miles, notes)
  select id, 500, 100, 'st-load' from public.customers where company_name = 'ST Test Broker';

-- ---------- replace + renumber ----------
select is(
  (select count(*) from public.replace_load_stops(
    (select id from public.loads where notes = 'st-load'),
    '[{"stop_type":"pickup","facility":"Shipper A"},
      {"stop_type":"pickup","facility":"Shipper B"},
      {"stop_type":"delivery","facility":"Receiver A"}]'::jsonb)),
  3::bigint,
  'replace_load_stops installs the new itinerary'
);

select is(
  (select array_agg(stop_type || ':' || seq order by stop_type desc, seq)
     from public.load_stops
    where load_id = (select id from public.loads where notes = 'st-load')),
  array['pickup:1','pickup:2','delivery:1'],
  'seq renumbers per stop type'
);

-- ---------- atomicity ----------
select throws_ok(
  $$select public.replace_load_stops(
      (select id from public.loads where notes = 'st-load'),
      '[{"stop_type":"pickup","facility":"New Shipper"},
        {"stop_type":"teleport","facility":"Nope"}]'::jsonb)$$,
  'stop_type must be pickup or delivery',
  'invalid stop rejects the batch'
);

select is(
  (select array_agg(facility order by stop_type desc, seq)
     from public.load_stops
    where load_id = (select id from public.loads where notes = 'st-load')),
  array['Shipper A','Shipper B','Receiver A'],
  'failed replace leaves the old itinerary untouched'
);

-- ---------- locks ----------
select set_config('app.load_rpc', '1', true);
update public.loads set status = 'cancelled' where notes = 'st-load';
select set_config('app.load_rpc', '', true);

select throws_ok(
  $$select public.replace_load_stops((select id from public.loads where notes = 'st-load'), '[]'::jsonb)$$,
  'Cancelled loads are locked; un-cancel first',
  'cancelled loads refuse itinerary edits'
);

select throws_ok(
  $$delete from public.load_stops
     where load_id = (select id from public.loads where notes = 'st-load')$$,
  'Cancelled loads are locked; un-cancel first',
  'the row-level guard also covers cancelled'
);

select * from finish();
rollback;
