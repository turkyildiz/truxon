-- Northstar flagship: load margin at booking. fleet_cost_basis() distills the
-- fleet's real economics from recent data so dispatch can predict a load's net
-- BEFORE accepting it (the app does the per-load arithmetic live as they type).
--   mpg              loaded miles ÷ gallons (ELD/fuel, 90d)
--   fuel_price       $/gal (30d)
--   pay_per_mile     avg active driver pay
--   fixed_per_mile   weekly truck fixed cost ÷ trailing weekly miles
--   toll_per_mile    tolls ÷ miles (90d)
--   breakeven_rpm    the rate/mile below which a load loses money
--   avg_rpm          fleet's trailing revenue/mile (for the "good/thin" verdict)
-- Admin/dispatcher/accountant.

create or replace function public.fleet_cost_basis()
returns jsonb
language plpgsql security definer set search_path = public stable as $$
declare
  v_loaded numeric; v_gal numeric; v_mpg numeric;
  v_fuel_price numeric; v_pay numeric;
  v_fixed_wk numeric; v_weekly_miles numeric; v_fixed_per_mile numeric;
  v_toll_per_mile numeric; v_avg_rpm numeric; v_breakeven numeric;
begin
  if public.my_role() not in ('admin', 'dispatcher', 'accountant') then
    raise exception 'Not enough permissions';
  end if;

  select coalesce(sum(miles), 0) into v_loaded from public.loads
   where status in ('completed', 'billed') and delivery_time > now() - interval '90 days';
  select coalesce(sum(gallons), 0) into v_gal from public.fuel_transactions
   where status <> 'Declined' and transaction_time > now() - interval '90 days';
  v_mpg := case when v_gal > 0 and v_loaded > 0 then round(v_loaded / v_gal, 2) else 6.5 end;

  select coalesce(round(sum(coalesce(net_of_discount, amount)) / nullif(sum(gallons), 0), 3), 4.00)
    into v_fuel_price from public.fuel_transactions
   where status <> 'Declined' and gallons > 0 and transaction_time > now() - interval '30 days';

  select coalesce(round(avg(pay_per_mile), 3), 0.60) into v_pay
    from public.drivers where status = 'active' and pay_per_mile > 0;

  select coalesce(sum(monthly_cost), 0) / 4.33 into v_fixed_wk from public.trucks where status <> 'retired';
  select coalesce(round(avg(wk_mi), 0), 0) into v_weekly_miles from (
    select public.trux_week_start(delivery_time::date) ws, sum(miles + coalesce(empty_miles, 0)) wk_mi
      from public.loads where status in ('completed', 'billed') and delivery_time > now() - interval '56 days'
     group by 1) t;
  v_fixed_per_mile := case when v_weekly_miles > 0 then round(v_fixed_wk / v_weekly_miles, 3) else 0 end;

  select coalesce(round(sum(t.toll_charge) / nullif((
           select sum(miles + coalesce(empty_miles, 0)) from public.loads
            where status in ('completed', 'billed') and delivery_time > now() - interval '90 days'), 0), 3), 0)
    into v_toll_per_mile from public.toll_transactions t
   where coalesce(t.post_date_time, t.exit_date_time) > now() - interval '90 days';

  select coalesce(round(sum(rate) / nullif(sum(miles), 0), 2), 0) into v_avg_rpm
    from public.loads where status in ('completed', 'billed') and delivery_time > now() - interval '56 days';

  v_breakeven := round(v_fuel_price / nullif(v_mpg, 0) + v_pay + v_fixed_per_mile + v_toll_per_mile, 2);

  return jsonb_build_object(
    'mpg', v_mpg, 'fuel_price', v_fuel_price, 'pay_per_mile', v_pay,
    'fixed_per_mile', v_fixed_per_mile, 'toll_per_mile', v_toll_per_mile,
    'breakeven_rpm', v_breakeven, 'avg_rpm', v_avg_rpm);
end;
$$;
revoke all on function public.fleet_cost_basis() from public, anon;
grant execute on function public.fleet_cost_basis() to authenticated;
