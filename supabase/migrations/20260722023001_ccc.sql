-- R8: cash conversion cycle (playbook #46). Full finance_march() redefinition
-- (latest = 20260722018001) adding dso_days / dpo_days / ccc_days.
create or replace function public.finance_march()
returns jsonb
language plpgsql security definer set search_path = public stable
as $$
declare
  out jsonb;
  cb jsonb;
  var_rpm numeric;
  be_rpm numeric;
  last_closed date := (date_trunc('month', now()) - interval '1 month')::date;
begin
  if auth.uid() is not null and public.my_role() not in ('admin', 'accountant') then
    raise exception 'Not enough permissions';
  end if;

  cb := public.fleet_cost_basis();
  var_rpm := coalesce((cb->>'fuel_price')::numeric / nullif((cb->>'mpg')::numeric, 0), 0)
             + coalesce((cb->>'pay_per_mile')::numeric, 0)
             + coalesce((cb->>'toll_per_mile')::numeric, 0);
  be_rpm := (cb->>'breakeven_rpm')::numeric;

  out := jsonb_build_object(
    -- #12 Revenue Growth YoY % — YTD (Jan..last closed month) vs same months
    -- prior year, GL income basis (GL mirror reaches Jan 2025)
    'ytd_revenue_growth_yoy_pct', (
      with cur as (select coalesce(sum(amount),0) v from gl_monthly
                    where grp = 'income'
                      and month >= date_trunc('year', now())::date and month <= last_closed),
           pri as (select coalesce(sum(amount),0) v from gl_monthly
                    where grp = 'income'
                      and month >= (date_trunc('year', now()) - interval '1 year')::date
                      and month <= (last_closed - interval '1 year')::date)
      select case when pri.v > 0 then round((cur.v - pri.v) / pri.v * 100, 1) end
        from cur, pri),
    -- #13 Freight Revenue (trailing 12m, booked loads)
    'freight_revenue_12m', coalesce((select sum(rate) from loads
        where status in ('completed','billed')
          and delivery_time >= now() - interval '12 months'), 0),
    -- #61 Lease Expense (trailing 12m, GL lease/rent/rental accounts)
    'lease_expense_12m', coalesce((select sum(amount) from gl_monthly
        where grp in ('expense','cogs') and account ~* 'lease|rental|rent'
          and month >= (date_trunc('month', now()) - interval '12 months')::date), 0),
    -- #105 QTD EBITDA Margin % — current-quarter GL months, depreciation/
    -- amortization added back (same account match as gl_balance_ratios)
    'qtd_ebitda_margin_pct', (
      with q as (
        select coalesce(sum(amount) filter (where grp in ('income','other_income')), 0) inc,
               coalesce(sum(amount) filter (where grp in ('cogs','expense')), 0) cost,
               coalesce(sum(amount) filter (where grp = 'expense' and account ~* 'depreciation|amortization'), 0) dep
          from gl_monthly where month >= date_trunc('quarter', now())::date)
      select case when q.inc > 0 then round((q.inc - q.cost + q.dep) / q.inc * 100, 1) end from q),
    -- #97 Profit Concentration: top-10 customers' share of total contribution
    -- (contribution = rate − total miles × variable cost/mile), trailing 12m
    'top10_profit_concentration_pct', (
      with contrib as (
        select l.customer_id,
               sum(l.rate - (coalesce(l.miles,0) + coalesce(l.empty_miles,0)) * var_rpm) as c
          from loads l
         where l.status in ('completed','billed')
           and l.delivery_time >= now() - interval '12 months'
         group by l.customer_id
      ), tot as (select sum(c) t from contrib where c > 0)
      select case when tot.t > 0
        then round((select sum(c) from (select c from contrib where c > 0 order by c desc limit 10) x) / tot.t * 100, 1) end
        from tot),
    -- #99/#100 revenue booked below cost (share of trailing-90d revenue on
    -- loads priced under variable / fully-allocated cost per mile)
    'pct_revenue_below_variable_cost', (
      with l as (select rate, coalesce(miles,0) + coalesce(empty_miles,0) mi from loads
                  where status in ('completed','billed') and delivery_time >= now() - interval '90 days'
                    and coalesce(miles,0) + coalesce(empty_miles,0) > 0)
      select case when sum(rate) > 0
        then round(coalesce(sum(rate) filter (where rate / mi < var_rpm), 0) / sum(rate) * 100, 1) end from l),
    'pct_revenue_below_full_cost', (
      with l as (select rate, coalesce(miles,0) + coalesce(empty_miles,0) mi from loads
                  where status in ('completed','billed') and delivery_time >= now() - interval '90 days'
                    and coalesce(miles,0) + coalesce(empty_miles,0) > 0)
      select case when sum(rate) > 0 and be_rpm is not null
        then round(coalesce(sum(rate) filter (where rate / mi < be_rpm), 0) / sum(rate) * 100, 1) end from l),
    -- #46 Cash Conversion Cycle = DSO - DPO (trucking holds no inventory,
    -- DIO ~ 0). DSO from open AR vs trailing-90d billings; DPO from the
    -- balance-sheet mirror's AP vs trailing-12m cost run-rate.
    'dso_days', (
      with ar as (select coalesce(sum(public.invoice_balance(i)),0) v from invoices i where i.status = 'sent'),
           b90 as (select coalesce(sum(i.total),0) v from invoices i
                    where i.status <> 'void' and i.invoice_date >= current_date - 90)
      select case when b90.v > 0 then round(ar.v / b90.v * 90, 1) end from ar, b90),
    'dpo_days', (
      with ap as (select coalesce((select bs.ap from bs_snapshot bs order by bs.as_of desc limit 1),0) v),
           c12 as (select coalesce(sum(amount),0) v from gl_monthly
                    where grp in ('cogs','expense')
                      and month >= (date_trunc('month', now()) - interval '12 months')::date)
      select case when c12.v > 0 then round(ap.v / (c12.v / 365.0), 1) end from ap, c12),
    'ccc_days', (
      with ar as (select coalesce(sum(public.invoice_balance(i)),0) v from invoices i where i.status = 'sent'),
           b90 as (select coalesce(sum(i.total),0) v from invoices i
                    where i.status <> 'void' and i.invoice_date >= current_date - 90),
           ap as (select coalesce((select bs.ap from bs_snapshot bs order by bs.as_of desc limit 1),0) v),
           c12 as (select coalesce(sum(amount),0) v from gl_monthly
                    where grp in ('cogs','expense')
                      and month >= (date_trunc('month', now()) - interval '12 months')::date)
      select case when b90.v > 0 and c12.v > 0
        then round(ar.v / b90.v * 90 - ap.v / (c12.v / 365.0), 1) end from ar, b90, ap, c12),
    'variable_rpm_used', round(var_rpm, 3),
    'breakeven_rpm_used', be_rpm,
    'as_of', now()
  );
  return out;
end;
$$;
revoke all on function public.finance_march() from public, anon;
grant execute on function public.finance_march() to authenticated, service_role;

update public.playbook_metrics set status='live', source='finance_march().ccc_days = DSO − DPO (no inventory)', updated_at=now() where number = 46;
