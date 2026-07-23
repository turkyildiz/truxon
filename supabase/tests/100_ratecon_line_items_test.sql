-- R9 #104/#105: rate-con line items — RLS boundaries, the reconciliation
-- report catches booked-vs-extracted drift, the sentinel fires on a mismatch
-- and auto-resolves once the numbers agree, and drivers can't see money rows.
begin;
create extension if not exists pgtap with schema extensions;
select plan(10);

insert into auth.users (id, email) values
  ('00000000-0000-4000-8000-0000000000e1'::uuid, 'rc-admin@test.local'),
  ('00000000-0000-4000-8000-0000000000e2'::uuid, 'rc-driver@test.local');
update public.profiles set role = 'admin'  where id = '00000000-0000-4000-8000-0000000000e1';
update public.profiles set role = 'driver' where id = '00000000-0000-4000-8000-0000000000e2';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000000e1"}', true);

insert into public.customers (company_name) values ('RC Broker');
insert into public.loads (customer_id, rate, miles, status, notes)
  select id, 1000, 300, 'pending', 'rc-mismatch' from public.customers where company_name='RC Broker';
insert into public.loads (customer_id, rate, miles, status, notes)
  select id, 500, 100, 'pending', 'rc-clean' from public.customers where company_name='RC Broker';

-- 1. table exists
select has_table('public'::name, 'load_line_items'::name, 'load_line_items table exists');

-- 2. kind is constrained
select throws_ok(
  $q$ insert into public.load_line_items (load_id, kind, amount)
      select id, 'tips', 50 from public.loads where notes='rc-mismatch' $q$,
  '23514', null, 'unknown line-item kind is rejected');

-- rate con itemizes to 1050 against a 1000 booking: line haul 900 + FSC 150
insert into public.load_line_items (load_id, kind, description, amount)
select id, 'line_haul', 'Line haul', 900 from public.loads where notes='rc-mismatch';
insert into public.load_line_items (load_id, kind, description, amount)
select id, 'fuel_surcharge', 'FSC', 150 from public.loads where notes='rc-mismatch';

-- 3. reconciliation report flags exactly this load with the right delta
select is(
  (select x->>'delta' from jsonb_array_elements(public.ratecon_recon_report(30)->'mismatches') x
    where (x->>'load_id')::bigint = (select id from public.loads where notes='rc-mismatch')),
  '50.00', 'recon report flags the $50 drift');

-- 4. fuel-surcharge capture is counted
select is(
  ((public.ratecon_recon_report(30)->'fuel_surcharge')->>'total_captured')::numeric,
  150::numeric, 'surcharge capture sums the FSC line');

-- 5. loads without extraction are reported honestly, not counted clean
select is(
  ((public.ratecon_recon_report(30)->>'not_extracted')::int >= 1),
  true, 'unextracted loads are surfaced as not_extracted');

-- 6. sentinel fires the mismatch as a money warn
select public.sentinel_scan();
select is(
  (select category||'/'||severity from public.trux_insights
    where dedup_key = 'ratecon_recon:'||(select id from public.loads where notes='rc-mismatch')),
  'money/warn', 'sentinel opens a money warn for the drift');

-- 7. correcting the booked rate resolves the finding on the next scan
select set_config('app.load_rpc','1',true);
update public.loads set rate = 1050 where notes='rc-mismatch';
select set_config('app.load_rpc','',true);
select public.sentinel_scan();
select is(
  (select status from public.trux_insights
    where dedup_key = 'ratecon_recon:'||(select id from public.loads where notes='rc-mismatch')),
  'resolved', 'finding auto-resolves once booked rate matches the paper');

-- 8. drivers see no line items (money data is office-only). RLS only bites
-- non-superuser roles — switch to `authenticated` or the check is a no-op.
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000000e2"}', true);
select is((select count(*) from public.load_line_items), 0::bigint, 'driver role sees zero line items');
reset role;

-- 9/10. fuel-surcharge recovery flip (#14/#69): captured FSC over fuel spend.
reset role;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000000e1"}', true);
insert into public.fuel_transactions (uuid, transaction_time, amount, net_of_discount, gallons, fuel_type)
  values ('rc-test-fuel-1', now() - interval '1 day', 620.00, 600.00, 160, 'Diesel');
select is(
  (public.fuel_surcharge_recovery(30)->>'fsc_captured')::numeric,
  150::numeric, 'recovery report sums captured FSC');
select is(
  (public.fuel_surcharge_recovery(30)->>'recovery_pct')::numeric,
  25.0::numeric, 'recovery pct = FSC / net-of-discount fuel spend');

select * from finish();
rollback;
