-- R8 (owner request): the truck form had nowhere to put the PAYMENT — the one
-- equipment cost the books structurally miss (loan principal never hits the
-- P&L; only interest and, if the accountant books it, depreciation do). Adds
-- ownership/payment/purchase columns, kills the empty-field NOT NULL error
-- class, and wires the payment into the cost-per-mile WITHOUT double-counting
-- what QuickBooks already carries (Equipment Rental + Interest Expense).
alter table public.trucks
  add column if not exists ownership text check (ownership in ('owned','financed','leased')),
  add column if not exists monthly_payment numeric(10,2) default 0,
  add column if not exists purchase_price numeric(12,2),
  add column if not exists purchase_date date;
alter table public.trailers
  add column if not exists ownership text check (ownership in ('owned','financed','leased')),
  add column if not exists monthly_payment numeric(10,2) default 0,
  add column if not exists purchase_price numeric(12,2),
  add column if not exists purchase_date date;

-- The form maps a cleared field to NULL; a NOT NULL default-0 column then
-- 23502s the whole save ("error messages if I try to put a value"). Every
-- reader already sum()/coalesce()s these, so nullable is safe.
alter table public.trucks alter column monthly_cost drop not null;
alter table public.trailers alter column monthly_cost drop not null;

-- fleet_cost_basis: full redefinition (latest = 20260720570001, GL-anchored).
-- New: the EQUIPMENT GAP — sum of per-truck payments MINUS what the books
-- already count for equipment (Equipment Rental + Interest, monthly avg over
-- the same trailing-3-month window), floored at 0, spread over monthly miles.
-- Leased trucks' rent is already in GL (gap ≈ 0); financed trucks' principal
-- is not (gap = the real number). Both bases benefit.
create or replace function public.fleet_cost_basis()
returns jsonb
language plpgsql security definer set search_path = public stable as $$
declare
  v_fuel_lo timestamptz; v_fuel_hi timestamptz;
  v_gal numeric; v_cov_mi numeric; v_mpg numeric;
  v_fuel_price numeric; v_pay numeric;
  v_fixed_wk numeric; v_weekly_miles numeric; v_fixed_per_mile numeric;
  v_toll_per_mile numeric; v_avg_rpm numeric; v_breakeven numeric;
  v_gl_costs numeric; v_gl_miles numeric; v_gl_rpm numeric;
  v_pay_mo numeric; v_gl_equip_mo numeric; v_equip_gap_mo numeric; v_equip_gap_pm numeric := 0;
  v_basis text := 'components';
begin
  if public.my_role() not in ('admin', 'dispatcher', 'accountant') then
    raise exception 'Not enough permissions';
  end if;

  select greatest(min(transaction_time), now() - interval '90 days'), max(transaction_time)
    into v_fuel_lo, v_fuel_hi
    from public.fuel_transactions where status <> 'Declined';
  select coalesce(sum(gallons), 0) into v_gal from public.fuel_transactions
   where status <> 'Declined' and transaction_time >= v_fuel_lo;
  select coalesce(sum(miles + coalesce(empty_miles, 0)), 0) into v_cov_mi from public.loads
   where status in ('completed', 'billed')
     and delivery_time >= v_fuel_lo and delivery_time <= coalesce(v_fuel_hi, now());
  v_mpg := case when v_gal > 0 and v_cov_mi > 0 then round(v_cov_mi / v_gal, 2) else 6.5 end;

  select coalesce(round(sum(coalesce(net_of_discount, amount)) / nullif(sum(gallons), 0), 3), 4.00)
    into v_fuel_price from public.fuel_transactions
   where status <> 'Declined' and gallons > 0 and transaction_time > now() - interval '30 days';

  select coalesce(round(avg(pay_per_mile), 3), 0.60) into v_pay
    from public.drivers where status = 'active' and pay_per_mile > 0;

  select coalesce(round(sum(t.toll_charge) / nullif((
           select sum(miles + coalesce(empty_miles, 0)) from public.loads
            where status in ('completed', 'billed') and delivery_time > now() - interval '90 days'), 0), 3), 0)
    into v_toll_per_mile from public.toll_transactions t
   where coalesce(t.post_date_time, t.exit_date_time) > now() - interval '90 days';

  select coalesce(round(sum(rate) / nullif(sum(miles), 0), 2), 0) into v_avg_rpm
    from public.loads where status in ('completed', 'billed') and delivery_time > now() - interval '56 days';

  select coalesce(sum(g.amount) filter (where g.grp in ('cogs','expense','other_expense')), 0)
    into v_gl_costs
    from public.gl_monthly g
   where g.month >= date_trunc('month', now()) - interval '3 months'
     and g.month < date_trunc('month', now());
  select coalesce(sum(l.miles + coalesce(l.empty_miles, 0)), 0) into v_gl_miles
    from public.loads l
   where l.status in ('delivered', 'completed', 'billed')
     and l.delivery_time >= date_trunc('month', now()) - interval '3 months'
     and l.delivery_time < date_trunc('month', now());
  v_gl_rpm := case when v_gl_miles > 0 and v_gl_costs > 0 then round(v_gl_costs / v_gl_miles, 3) end;

  -- Equipment gap: form payments vs what the books already count
  select coalesce(sum(monthly_payment), 0) into v_pay_mo
    from public.trucks where status <> 'retired';
  select coalesce(sum(g.amount), 0) / 3.0 into v_gl_equip_mo
    from public.gl_monthly g
   where g.account ~* 'equipment rental|truck rental|interest'
     and g.month >= date_trunc('month', now()) - interval '3 months'
     and g.month < date_trunc('month', now());
  v_equip_gap_mo := greatest(v_pay_mo - v_gl_equip_mo, 0);

  if v_gl_rpm is not null then
    v_basis := 'gl';
    if v_equip_gap_mo > 0 and v_gl_miles > 0 then
      v_equip_gap_pm := round(v_equip_gap_mo / (v_gl_miles / 3.0), 3);
      v_basis := 'gl+equipment';
    end if;
    v_breakeven := round(v_gl_rpm + v_equip_gap_pm, 2);
    v_fixed_per_mile := greatest(round(v_gl_rpm + v_equip_gap_pm - v_fuel_price / nullif(v_mpg, 0) - v_pay - v_toll_per_mile, 3), 0);
  else
    select (coalesce(sum(coalesce(monthly_cost, 0)), 0) + coalesce(sum(coalesce(monthly_payment, 0)), 0)) / 4.33
      into v_fixed_wk from public.trucks where status <> 'retired';
    select coalesce(round(avg(wk_mi), 0), 0) into v_weekly_miles from (
      select public.trux_week_start(delivery_time::date) ws, sum(miles + coalesce(empty_miles, 0)) wk_mi
        from public.loads where status in ('completed', 'billed') and delivery_time > now() - interval '56 days'
       group by 1) t;
    v_fixed_per_mile := case when v_weekly_miles > 0 then round(v_fixed_wk / v_weekly_miles, 3) else 0 end;
    v_breakeven := round(v_fuel_price / nullif(v_mpg, 0) + v_pay + v_fixed_per_mile + v_toll_per_mile, 2);
  end if;

  return jsonb_build_object(
    'mpg', v_mpg, 'fuel_price', v_fuel_price, 'pay_per_mile', v_pay,
    'fixed_per_mile', v_fixed_per_mile, 'toll_per_mile', v_toll_per_mile,
    'breakeven_rpm', v_breakeven, 'avg_rpm', v_avg_rpm,
    'gl_all_in_rpm', v_gl_rpm, 'basis', v_basis,
    'equipment_gap_per_mile', v_equip_gap_pm,
    'fuel_data_from', v_fuel_lo::date);
end;
$$;
revoke all on function public.fleet_cost_basis() from public, anon;
grant execute on function public.fleet_cost_basis() to authenticated;
