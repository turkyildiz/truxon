-- Auto-budget: missing lines seed from trailing-3-month actuals, manual rows
-- are never overwritten, variance math works against the seeded budget, and
-- the scorecard now carries budget/insurance/balance with a shrunken
-- not_captured list.
begin;
create extension if not exists pgtap with schema extensions;
select plan(7);

-- 3 months of actuals: $30k/mo revenue via delivered loads
insert into public.customers (company_name) values ('Budget Co');
insert into public.loads (load_number, customer_id, status, rate, miles, delivery_time)
select 'BUD-'||g, (select id from public.customers where company_name = 'Budget Co'),
       'completed', 30000, 5000,
       date_trunc('month', now()) - interval '3 months' + (interval '1 month' * (g - 1)) + interval '5 days'
from generate_series(1, 3) g;

-- a manual revenue budget already exists for THIS month → must survive
insert into public.budgets (period_month, line, amount, basis)
values (date_trunc('month', now())::date, 'revenue', 99999, 'manual');

select ok(public.ensure_auto_budget() >= 0, 'seeding runs');
select is(
  (select amount from public.budgets
    where period_month = date_trunc('month', now())::date and line = 'revenue'),
  99999.00, 'a manual budget row is never overwritten by the auto-seed');

-- wipe the manual row and re-seed → auto revenue = 90k/3 = 30k
delete from public.budgets where line = 'revenue';
select ok(public.ensure_auto_budget() >= 1, 're-seed fills the now-missing line');
select is(
  (select basis from public.budgets
    where period_month = date_trunc('month', now())::date and line = 'revenue'),
  'auto', 'seeded rows carry basis=auto');
select is(
  (select amount from public.budgets
    where period_month = date_trunc('month', now())::date and line = 'revenue'),
  30000.00, 'auto budget = trailing 3-month average of actuals');

-- scorecard integration
select ok(
  (public.company_scorecard(date_trunc('month', now()), now()))->'budget' is not null,
  'scorecard carries the budget section');
select is(
  (select count(*)::int from jsonb_array_elements_text(
     public.company_scorecard(now() - interval '7 days', now())->'not_captured')),
  2, 'not_captured is down to the two honest gaps');

select * from finish();
rollback;
