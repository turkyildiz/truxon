-- R3 #2: scenario math from a controlled GL: rev 100k, fuel 20k, ins 10k,
-- other 50k → net 20k. Cash 120k.
begin;
create extension if not exists pgtap with schema extensions;
select plan(8);

insert into auth.users (id, email) values
  ('00000000-0000-4000-8000-000000000f77'::uuid, 'st-admin@test.local'),
  ('00000000-0000-4000-8000-000000000f78'::uuid, 'st-driver@test.local');
update public.profiles set role = 'admin'  where id = '00000000-0000-4000-8000-000000000f77';
update public.profiles set role = 'driver' where id = '00000000-0000-4000-8000-000000000f78';

delete from public.gl_monthly;
insert into public.gl_monthly (month, account, grp, amount)
select m, a.account, a.grp, a.amount
from (select date_trunc('month', current_date)::date - (interval '1 month' * n) as m
        from generate_series(1, 3) n) months,
     (values ('Freight income', 'income', 100000::numeric),
             ('Fuel expense', 'cogs', 20000),
             ('Insurance - trucks', 'expense', 10000),
             ('Driver pay', 'cogs', 50000)) as a(account, grp, amount);
insert into public.bs_snapshot (as_of, cash, ar, ap, current_assets, current_liabilities,
                                total_assets, total_liabilities, equity)
values (current_date, 120000, 0, 0, 0, 0, 0, 0, 0);

select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000f77"}', true);

select is((public.scenario_runway(0,0,0)->'baseline'->>'monthly_net')::numeric, 20000::numeric,
  'baseline net = 100k - 80k');
select is(public.scenario_runway(0,0,0)->>'runway_months', null,
  'positive net means no runway clock');

-- revenue -25%: rev 75k, fuel 15k (scales), ins 10k, other 50k → net 0
select is((public.scenario_runway(-25,0,0)->'shocked'->>'monthly_net')::numeric, 0::numeric,
  'revenue -25 pct: fuel scales down with volume, net hits zero');

-- perfect storm -25/+40/+30: rev 75k, fuel 20k*0.75*1.4=21k, ins 13k, other 50k → net -9k
select is((public.scenario_runway(-25,40,30)->'shocked'->>'monthly_net')::numeric, -9000::numeric,
  'perfect storm burns 9k/month');
select is((public.scenario_runway(-25,40,30)->>'runway_months')::numeric, round(120000/9000.0, 1),
  'runway = cash / burn');

select is(jsonb_typeof(public.stress_test()->'perfect_storm'), 'object',
  'stress pack bundles all scenarios');

-- negative book cash (factoring/overdraft artifact) clamps runway at 0
update public.bs_snapshot set cash = -50000;
select is((public.scenario_runway(-25,40,30)->>'runway_months')::numeric, 0.0::numeric,
  'negative cash means zero runway, never negative months');
update public.bs_snapshot set cash = 120000;

select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000f78"}', true);
select throws_ok('select public.stress_test()', 'P0001', 'Not enough permissions',
  'stress test is admin/accountant only');

select * from finish();
rollback;
