-- GL mirror: upsert semantics, true P&L math, break-even RPM, CFO snapshot,
-- gates, and the playbook flips.
begin;
create extension if not exists pgtap with schema extensions;
select plan(12);

-- ── service upserts (no user context) ──
select set_config('request.jwt.claims', '', true);

select is(public.gl_upsert_monthly(jsonb_build_array(
  jsonb_build_object('month','2026-06-01','account','Sales','grp','income','amount',100000),
  jsonb_build_object('month','2026-06-01','account','Fuel','grp','cogs','amount',30000),
  jsonb_build_object('month','2026-06-01','account','Vendor Expense','grp','cogs','amount',25000),
  jsonb_build_object('month','2026-06-01','account','Insurance','grp','expense','amount',15000),
  jsonb_build_object('month','2026-06-01','account','Interest Expense','grp','expense','amount',2000)
)), 5, 'five GL rows land');

-- replace-by-month: re-sync of the same month replaces, never duplicates
select is(public.gl_upsert_monthly(jsonb_build_array(
  jsonb_build_object('month','2026-06-01','account','Sales','grp','income','amount',100000),
  jsonb_build_object('month','2026-06-01','account','Fuel','grp','cogs','amount',31000),
  jsonb_build_object('month','2026-06-01','account','Vendor Expense','grp','cogs','amount',25000),
  jsonb_build_object('month','2026-06-01','account','Insurance','grp','expense','amount',15000),
  jsonb_build_object('month','2026-06-01','account','Interest Expense','grp','expense','amount',2000)
)), 5, 're-sync replaces the month');
select is((select count(*)::int from public.gl_monthly where month = '2026-06-01'), 5, 'no duplicate rows after re-sync');

select lives_ok($$select public.bs_upsert(jsonb_build_object(
  'as_of', current_date, 'cash', 250000, 'ar', 300000, 'ap', 80000,
  'current_assets', 600000, 'current_liabilities', 200000,
  'total_assets', 900000, 'total_liabilities', 350000, 'equity', 550000))$$,
  'balance-sheet snapshot lands');

-- miles for break-even (June delivery)
insert into public.customers (company_name) values ('GL Test Broker');
insert into public.loads (load_number, customer_id, status, pickup_address, delivery_address, rate, miles, empty_miles, delivery_time)
  select 'L-GL-1', id, 'completed', 'A', 'B', 100000, 40000, 10000, '2026-06-15'::timestamptz
  from public.customers where company_name = 'GL Test Broker';

-- ── admin reads ──
insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000d01'::uuid, 'gl@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000d01';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000d01"}', true);

-- P&L math: income 100k, cogs 56k, opex 17k → net 27k, OR 73%
select is((select net_income from public.gl_pnl_monthly(2) where month = '2026-06'), 27000::numeric, 'net income from all cost groups');
select is((select operating_ratio from public.gl_pnl_monthly(2) where month = '2026-06'), 73.0::numeric, 'TRUE operating ratio (all costs / revenue)');

-- break-even: costs 73k / 50k mi = 1.46; actual 100k / 50k = 2.0
select is((select rpm_breakeven from public.gl_breakeven_monthly(2) where month = '2026-06'), 1.460::numeric, 'break-even RPM from all costs and loaded+empty miles');
select is((select rpm_actual from public.gl_breakeven_monthly(2) where month = '2026-06'), 2.000::numeric, 'actual RPM');

-- expense breakdown: Insurance 15% of revenue
select is((select pct_of_revenue from public.gl_expense_breakdown(2) where account = 'Insurance'), 15.00::numeric, 'insurance % of revenue');

-- CFO snapshot: current ratio 3.0
select is((public.gl_cfo_snapshot()->>'current_ratio')::numeric, 3.00::numeric, 'current ratio from the snapshot');

-- a signed-in user must NOT reach the service upsert
select throws_ok(
  $$select public.gl_upsert_monthly('[]'::jsonb)$$,
  'Not enough permissions',
  'browser sessions cannot write the GL');

-- playbook flips landed
select is((select count(*)::int from public.playbook_metrics
            where number in (24,25,36,37,38,45,47,48,50,54,86) and status = 'live'),
  11, 'eleven metrics flipped live by the GL mirror');

select * from finish();
rollback;
