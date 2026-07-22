-- finance_march(): YoY from GL, below-cost revenue shares, top-10 concentration.
begin;
create extension if not exists pgtap with schema extensions;
select plan(4);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000113'::uuid, 'fin@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000113';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000113"}', true);

-- GL: this-year YTD income 120K vs prior-year same months 100K → +20%
insert into public.gl_monthly (month, account, grp, amount, source)
select m::date, 'Freight Income', 'income', amt, 'test'
from (values
  (date_trunc('year', now()), 60000),
  (date_trunc('year', now()) + interval '1 month', 60000),
  (date_trunc('year', now()) - interval '1 year', 50000),
  (date_trunc('year', now()) - interval '11 months', 50000)
) v(m, amt);

select ok(
  (public.finance_march()->>'ytd_revenue_growth_yoy_pct')::numeric between 19 and 21,
  'YTD YoY growth ≈ +20% from GL income');

-- below-cost shares: with no loads seeded in 90d the shares are null-or-zero,
-- and the function must not error when fleet_cost_basis has thin data
select ok(public.finance_march() ? 'pct_revenue_below_variable_cost', 'below-variable key present');
select ok(public.finance_march() ? 'top10_profit_concentration_pct', 'concentration key present');
select is(
  (select status from public.playbook_metrics where number = 105), 'live',
  'playbook #105 flipped live');

select * from finish();
rollback;
