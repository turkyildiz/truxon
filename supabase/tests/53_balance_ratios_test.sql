-- Balance-sheet ratios off the GL mirror: debt/equity, net debt, ROE compute
-- from seeded bs_snapshot + gl_monthly; empty mirror says so instead of lying;
-- the nightly capture picks the ratios up as balance.* series.
begin;
create extension if not exists pgtap with schema extensions;
select plan(8);

-- empty mirror → available:false (never fabricate)
delete from public.bs_snapshot;
select is((public.gl_balance_ratios()->>'available')::boolean, false,
  'no snapshot yet → available:false');

-- seed: $500k assets, $300k liabilities ($50k of it AP), $200k equity, $100k cash
insert into public.bs_snapshot (as_of, cash, ar, ap, current_assets, current_liabilities,
                                total_assets, total_liabilities, equity)
values (current_date, 100000, 150000, 50000, 260000, 90000, 500000, 300000, 200000);

-- 12 months of P&L: 40k income, 25k expense (2k of it depreciation) per month
insert into public.gl_monthly (month, account, grp, amount)
select date_trunc('month', now()) - (interval '1 month' * g), 'Freight Income', 'income', 40000
from generate_series(0, 11) g;
insert into public.gl_monthly (month, account, grp, amount)
select date_trunc('month', now()) - (interval '1 month' * g), 'Operating Expense', 'expense', 23000
from generate_series(0, 11) g;
insert into public.gl_monthly (month, account, grp, amount)
select date_trunc('month', now()) - (interval '1 month' * g), 'Depreciation Expense', 'expense', 2000
from generate_series(0, 11) g;

-- debt = 300k − 50k AP = 250k; net debt = 250k − 100k cash = 150k
select is((public.gl_balance_ratios()->>'debt')::numeric, 250000::numeric, 'debt strips AP from liabilities');
select is((public.gl_balance_ratios()->>'net_debt')::numeric, 150000::numeric, 'net debt subtracts cash');
select is((public.gl_balance_ratios()->>'debt_to_equity')::numeric, 1.25::numeric, 'debt/equity = 250k/200k');
-- NOI 12m = (40k−25k)*12 = 180k; EBITDA = 180k + 24k dep = 204k; 150k/204k ≈ 0.74
select is((public.gl_balance_ratios()->>'net_debt_to_ebitda')::numeric, 0.74::numeric, 'net debt / EBITDA with D&A add-back');
-- net income = NOI (no other_expense seeded) = 180k / 200k equity = 90%
select is((public.gl_balance_ratios()->>'roe_12m_pct')::numeric, 90.0::numeric, 'ROE from 12m net income');

-- nightly capture now carries balance.* series
select ok(public.capture_metric_snapshots() > 0, 'capture runs with balance ratios folded in');
select ok(exists(select 1 from public.metric_snapshots
                 where metric_key = 'balance.net_debt' and captured_on = current_date),
  'balance.net_debt landed in the series');

select * from finish();
rollback;
