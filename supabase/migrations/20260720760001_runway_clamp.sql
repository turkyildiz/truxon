-- R3 #2 fix — the books' cash is currently NEGATIVE (-$72.8K on bs_snapshot,
-- a factoring/overdraft artifact), which made runway compute to -3.7 months.
-- Runway is time-until-empty: with no positive cash it is 0, not negative.
create or replace function public.scenario_runway(
  p_revenue_pct numeric default 0,
  p_fuel_pct numeric default 0,
  p_insurance_pct numeric default 0
)
returns jsonb
language plpgsql security definer set search_path = public stable
as $$
declare
  v_from date := date_trunc('month', current_date) - interval '3 months';
  v_to   date := date_trunc('month', current_date);
  v_rev numeric; v_fuel numeric; v_ins numeric; v_other numeric;
  v_cash numeric;
  s_rev numeric; s_fuel numeric; s_ins numeric; s_net numeric;
  v_net numeric;
begin
  if auth.uid() is not null and public.my_role() not in ('admin', 'accountant') then
    raise exception 'Not enough permissions';
  end if;

  select coalesce(sum(amount) filter (where grp = 'income'), 0) / 3.0,
         coalesce(sum(amount) filter (where grp <> 'income' and (account ilike '%fuel%' or account ilike '%diesel%')), 0) / 3.0,
         coalesce(sum(amount) filter (where grp <> 'income' and account ilike '%insurance%'), 0) / 3.0,
         coalesce(sum(amount) filter (where grp <> 'income'
                                        and account not ilike '%fuel%' and account not ilike '%diesel%'
                                        and account not ilike '%insurance%'), 0) / 3.0
    into v_rev, v_fuel, v_ins, v_other
    from gl_monthly
   where month >= v_from and month < v_to
     and grp in ('income', 'cogs', 'expense', 'other_expense');

  select cash into v_cash from bs_snapshot order by as_of desc limit 1;
  v_cash := coalesce(v_cash, 0);
  v_net := v_rev - v_fuel - v_ins - v_other;

  s_rev  := v_rev * (1 + p_revenue_pct / 100.0);
  s_fuel := v_fuel * (1 + p_revenue_pct / 100.0) * (1 + p_fuel_pct / 100.0);
  s_ins  := v_ins * (1 + p_insurance_pct / 100.0);
  s_net  := s_rev - s_fuel - s_ins - v_other;

  return jsonb_build_object(
    'window', jsonb_build_object('from', v_from, 'to', v_to, 'months', 3),
    'baseline', jsonb_build_object(
      'monthly_revenue', round(v_rev), 'monthly_fuel', round(v_fuel),
      'monthly_insurance', round(v_ins), 'monthly_other_costs', round(v_other),
      'monthly_net', round(v_net), 'cash', round(v_cash)),
    'shock', jsonb_build_object(
      'revenue_pct', p_revenue_pct, 'fuel_pct', p_fuel_pct, 'insurance_pct', p_insurance_pct),
    'shocked', jsonb_build_object(
      'monthly_revenue', round(s_rev), 'monthly_fuel', round(s_fuel),
      'monthly_insurance', round(s_ins), 'monthly_net', round(s_net)),
    'runway_months', case when s_net >= 0 then null
                          else round(greatest(v_cash, 0) / abs(s_net), 1) end,
    'survives', s_net >= 0 or greatest(v_cash, 0) / abs(s_net) >= 6,
    'assumptions', 'GL trailing 3 full months; fuel scales with revenue and its own price; insurance and other costs fixed; runway ignores AR timing/factoring. Cash below zero (books overdraft/factoring artifact) counts as zero runway fuel.');
end;
$$;
