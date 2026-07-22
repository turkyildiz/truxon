-- Credit-exposure sentinel (20260722009004): a broker whose float exceeds its
-- pay-history limit fires a cash finding; paying down / clearing loads resolves.
begin;
create extension if not exists pgtap with schema extensions;
select plan(5);

insert into auth.users (id, email) values
  ('00000000-0000-4000-8000-00000000e201'::uuid, 'exp@test.local'),
  ('00000000-0000-4000-8000-00000000e202'::uuid, 'drv@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-00000000e201';
update public.profiles set role = 'driver' where id = '00000000-0000-4000-8000-00000000e202';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-00000000e201"}', true);

insert into public.customers (company_name) values ('Overexposed Broker');
-- $20k committed loads, no billing history → $5k floor limit → $15k over
insert into public.loads (load_number, customer_id, status, rate, miles)
select 'EXP-' || g, id, 'assigned', 5000, 500
  from public.customers, generate_series(1,4) g where company_name = 'Overexposed Broker';

select is((select over_by from public.customers_over_exposure() limit 1), 15000::numeric,
  'over_by = exposure ($20k) − limit ($5k floor)');
select public.sentinel_scan();
select ok(exists(select 1 from public.trux_insights where dedup_key like 'over_exposure:%' and status = 'open'),
  'over-exposed broker fires a cash finding');

-- drop the exposure (delete the committed loads) → resolves
delete from public.loads where load_number like 'EXP-%';
select is((select count(*)::int from public.customers_over_exposure()), 0, 'no over-exposed customers after paydown');
select public.sentinel_scan();
select is((select status from public.trux_insights where dedup_key like 'over_exposure:%'),
  'resolved', 'clearing the exposure auto-resolves the finding');

select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-00000000e202"}', true);
select throws_ok('select public.customers_over_exposure()', 'P0001', 'Not enough permissions',
  'customers_over_exposure gated away from drivers');

select * from finish();
rollback;
