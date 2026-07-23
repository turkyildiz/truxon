-- R9 #40: gl_cfo_snapshot v2 — the TRUE operating ratio including the
-- equipment payments the P&L mirror can't see (truck/trailer payments from
-- the equipment forms minus GL equipment/interest lines, annualized).
-- Reproduced WHOLE from 20260719480001.
create or replace function public.gl_cfo_snapshot()
returns jsonb
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  bs bs_snapshot;
  v_rev12 numeric;
  v_costs12 numeric;
  v_noi12 numeric;
  v_interest12 numeric;
  v_risk12 numeric;
  v_trucks int;
  v_equip_gap12 numeric;
begin
  if public.my_role() <> 'admin' then
    raise exception 'Not enough permissions';
  end if;
  select * into bs from bs_snapshot order by as_of desc limit 1;
  select
    coalesce(sum(amount) filter (where grp = 'income'), 0),
    coalesce(sum(amount) filter (where grp in ('cogs', 'expense', 'other_expense')), 0),
    coalesce(sum(amount) filter (where grp = 'income'), 0)
      - coalesce(sum(amount) filter (where grp in ('cogs', 'expense')), 0),
    coalesce(sum(amount) filter (where account ~* 'interest'), 0),
    coalesce(sum(amount) filter (where account ~* 'insurance|physical damage|penalt|settlement|claim'), 0)
  into v_rev12, v_costs12, v_noi12, v_interest12, v_risk12
  from gl_monthly where month >= date_trunc('month', now()) - interval '11 months';
  select count(*) into v_trucks from trucks where status <> 'retired';
  -- (R9 #40) equipment the P&L can't see: truck/trailer payments entered on
  -- the equipment forms minus whatever the GL already carries as equipment
  -- rental / truck rental / interest, annualized and floored at 0.
  select greatest(
      ((select coalesce(sum(monthly_payment), 0) from trucks where status <> 'retired')
       + (select coalesce(sum(monthly_payment), 0) from trailers where status <> 'retired')) * 12
      - coalesce((select sum(amount) from gl_monthly
                   where account ~* 'equipment rental|truck rental|interest'
                     and month >= date_trunc('month', now()) - interval '11 months'), 0),
      0) into v_equip_gap12;

  return jsonb_build_object(
    'as_of', bs.as_of,
    'cash', bs.cash,
    'ap', bs.ap,
    'working_capital', case when bs.current_assets is not null and bs.current_liabilities is not null
                         then bs.current_assets - bs.current_liabilities end,
    'working_capital_pct_revenue', case when v_rev12 > 0 and bs.current_assets is not null and bs.current_liabilities is not null
                                     then round((bs.current_assets - bs.current_liabilities) / v_rev12 * 100, 1) end,
    'current_ratio', case when coalesce(bs.current_liabilities, 0) > 0
                       then round(bs.current_assets / bs.current_liabilities, 2) end,
    'dpo', case when v_costs12 > 0 and bs.ap is not null then round(bs.ap / v_costs12 * 365, 1) end,
    'days_of_cash', case when v_costs12 > 0 and bs.cash is not null then round(bs.cash / (v_costs12 / 365), 1) end,
    'interest_coverage', case when v_interest12 > 0 then round(v_noi12 / v_interest12, 1) end,
    'overhead_per_tractor_month', case when v_trucks > 0 then round(
      (select coalesce(sum(amount), 0) from gl_monthly where grp = 'expense' and month >= date_trunc('month', now()) - interval '11 months')
      / v_trucks / 12, 0) end,
    'total_cost_of_risk_12m', v_risk12,
    'revenue_12m', v_rev12,
    'operating_ratio_12m', case when v_rev12 > 0 then round(v_costs12 / v_rev12 * 100, 1) end,
    'equipment_gap_12m', round(v_equip_gap12, 0),
    'operating_ratio_equip_adj', case when v_rev12 > 0
      then round((v_costs12 + v_equip_gap12) / v_rev12 * 100, 1) end
  );
end;
$$;
revoke all on function public.gl_cfo_snapshot() from public, anon;
grant execute on function public.gl_cfo_snapshot() to authenticated, service_role;
