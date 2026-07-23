-- Accounting-module audit (owner-requested) — the factored/fee-sliver class
-- had leaked back into four functions written outside yesterday's factoring
-- AR sweep (20260721236001, which fixed collections/slow-pay/exposure/
-- forecast/snapshots/aging):
--   1. company_scorecard: headline AR included factored reserves + fee slivers
--   2. finance_extras: AR>45/60/90 buckets included factored rows
--   3. finance_march: DSO + cash-conversion-cycle counted factored AR
--   4. acct_summary: factoring_reserve counted the fee sliver as cash still
--      coming (it isn't - it's the factor's fee), and mtd_collected counted
--      factored invoices gross instead of net of fee.


create or replace function public.company_scorecard(p_start timestamptz, p_end timestamptz)
returns jsonb
language plpgsql stable security definer set search_path = public
as $body$
declare
  win_days numeric := greatest(extract(epoch from (p_end - p_start)) / 86400.0, 1);
  weeks numeric := greatest(win_days / 7.0, 0.1);
  revenue numeric; loaded_mi numeric; total_mi numeric; empty_mi numeric; loads_n int;
  fuel numeric; tolls numeric; driver_pay numeric; maint numeric; truck_fixed numeric;
  gal numeric; active_trucks int; trailers_n int;
  ar_out numeric; billed numeric; voided numeric;
  top5 numeric; customers_n int; newlogo numeric;
  avg_tractor_age numeric; avg_trailer_age numeric; inv_cycle numeric;
  total_cost numeric;
  gl_income numeric; gl_costs numeric; gl_months int;
  det_events int; det_min numeric; det_pay numeric;
  s record; csa_alerts int; acc_n int; prev_n int; oos_n int;
  veh_conn int; gps_live int; drivers_tracked int; low_hos int;
  ot_meas int; ot_hit int;
  eld_mi numeric; eld_mpg numeric;   -- day-matched telematics MPG (R8 Block 1)
  v_sales jsonb;
begin
  if public.my_role() not in ('admin','accountant','dispatcher') then
    raise exception 'Not enough permissions';
  end if;

  select coalesce(sum(rate),0), coalesce(sum(miles),0), coalesce(sum(empty_miles),0), count(*)
    into revenue, loaded_mi, empty_mi, loads_n
    from public.loads
   where status in ('completed','billed') and delivery_time >= p_start and delivery_time < p_end;
  total_mi := loaded_mi + empty_mi;

  select coalesce(sum(coalesce(net_of_discount,amount)),0), coalesce(sum(gallons),0) into fuel, gal
    from public.fuel_transactions where status <> 'Declined' and transaction_time >= p_start and transaction_time < p_end;
  select coalesce(sum(toll_charge),0) into tolls from public.toll_transactions
   where coalesce(post_date_time,exit_date_time) >= p_start and coalesce(post_date_time,exit_date_time) < p_end;
  select coalesce(sum(l.miles*d.pay_per_mile + case when d.empty_miles_paid then coalesce(l.empty_miles,0)*d.pay_per_empty_mile else 0 end),0)
    into driver_pay from public.loads l join public.drivers d on d.id=l.driver_id
   where l.status in ('completed','billed') and l.delivery_time >= p_start and l.delivery_time < p_end;
  select coalesce(sum(cost),0) into maint from public.maintenance_records
   where date_completed >= p_start::date and date_completed < p_end::date;
  select coalesce(round(sum(monthly_cost)*(win_days/30.44),2),0), count(*) into truck_fixed, active_trucks
    from public.trucks where status <> 'retired';
  select count(*) into trailers_n from public.trailers where status <> 'retired';
  total_cost := fuel + tolls + driver_pay + maint + truck_fixed;

  -- actual ELD miles + day-matched MPG (fuel counts only on GPS-covered days)
  select f.eld_miles, f.mpg into eld_mi, eld_mpg
    from public.eld_fleet_mpg(p_start::date, p_end::date) f;

  select coalesce(sum(amount) filter (where grp = 'income'), 0),
         coalesce(sum(amount) filter (where grp in ('cogs', 'expense', 'other_expense')), 0),
         count(distinct month)
    into gl_income, gl_costs, gl_months
    from gl_monthly
   where month >= date_trunc('month', p_start)::date
     and month < p_end::date
     and win_days >= 28;  -- GL is monthly-grained: for sub-month windows the
                          -- overlap would return whole-month totals (caught
                          -- live: W28 digest showed monthly net on weekly
                          -- revenue). Short windows keep the operational basis.

  -- AR / bad debt
  -- OUTSTANDING balance, not face total: QBO-mirror invoices carry factoring-fee
  -- residuals and partial payments; sum(total) overstated open AR ~3x (exam find).
  select coalesce(sum(public.invoice_balance(i)),0) into ar_out from public.invoices i where i.status='sent' and i.factored_at is null; -- factored = sold, not our AR
  select coalesce(sum(total),0) into billed from public.invoices where status in ('sent','paid') and invoice_date >= p_start and invoice_date < p_end;
  select coalesce(sum(total),0) into voided from public.invoices where status='void' and invoice_date >= p_start and invoice_date < p_end;

  -- customer concentration + new-logo (customers created in last 12 months)
  select coalesce(sum(rev),0) from (
    select l.customer_id, sum(l.rate) rev from public.loads l
     where l.status in ('completed','billed') and l.delivery_time >= p_start and l.delivery_time < p_end
     group by l.customer_id order by rev desc limit 5) t into top5;
  select count(distinct customer_id) into customers_n from public.loads
   where status in ('completed','billed') and delivery_time >= p_start and delivery_time < p_end;
  select coalesce(sum(l.rate),0) into newlogo from public.loads l join public.customers c on c.id=l.customer_id
   where l.status in ('completed','billed') and l.delivery_time >= p_start and l.delivery_time < p_end
     and c.id in (select id from public.customers where created_at > now() - interval '12 months');

  -- fleet age (from year if present) + invoice cycle time
  select round(avg(extract(year from now()) - year),1) into avg_tractor_age from public.trucks where status<>'retired' and year is not null;
  select round(avg(extract(year from now()) - year),1) into avg_trailer_age from public.trailers where status<>'retired' and year is not null;
  select round(avg(extract(epoch from (i.invoice_date - l.delivery_time))/86400.0),1) into inv_cycle
    from public.loads l join public.invoices i on i.id = l.invoice_id
   where l.delivery_time >= p_start and l.delivery_time < p_end and l.delivery_time is not null;

  -- ===== NEWLY CAPTURED =====
  -- Detention (ELD dwell vs free time) over a trailing window matching the scorecard.
  select count(*), coalesce(sum(detention_min),0), coalesce(sum(est_pay),0)
    into det_events, det_min, det_pay
    from public.detention_events(greatest(ceil(win_days)::int, 1));

  -- Safety: latest FMCSA snapshot + CSA alerts + in-window safety events.
  select * into s from public.carrier_safety_snapshot order by snapshot_date desc limit 1;
  select count(*) filter (where alert) into csa_alerts from public.safety_csa;
  select count(*) filter (where event_type='accident'),
         count(*) filter (where event_type='accident' and preventable),
         count(*) filter (where out_of_service)
    into acc_n, prev_n, oos_n
    from public.safety_events where event_date >= p_start::date and event_date < p_end::date;

  -- Telematics/HOS: ELD connectivity + live GPS + drivers low on drive hours.
  select count(*) filter (where truck_id is not null) into veh_conn from public.eld_vehicles;
  select count(*) into gps_live from public.eld_vehicle_status where lat is not null and ts > now() - interval '2 hours';
  select count(*) filter (where drive_sec is not null),
         count(*) filter (where drive_sec is not null and drive_sec < 3600)
    into drivers_tracked, low_hos from public.eld_driver_status;

  -- On-time delivery: of in-window loads with an ELD arrival near the delivery
  -- stop, the share that arrived by the appointment (+2h grace).
  with arr as (
    select l.delivery_time,
           (select min(h.ts) from public.eld_location_history h
             where h.truck_id = l.truck_id
               and h.ts between l.delivery_time - interval '18 hours' and l.delivery_time + interval '18 hours'
               and public.trux_miles(l.delivery_lat, l.delivery_lon, h.lat, h.lng) <= 0.75) as eld_arr
      from public.loads l
     where l.status in ('completed','billed') and l.delivery_time >= p_start and l.delivery_time < p_end
       and l.truck_id is not null and l.delivery_lat is not null and l.delivery_time is not null
  )
  select count(*) filter (where eld_arr is not null),
         count(*) filter (where eld_arr is not null and eld_arr <= delivery_time + interval '2 hours')
    into ot_meas, ot_hit from arr;

  v_sales := public.sales_pipeline(p_start, p_end);

  return jsonb_build_object(
    'window', jsonb_build_object('start', p_start, 'end', p_end, 'days', round(win_days,1)),
    'financial', jsonb_build_object(
      'revenue', round(revenue,2),
      'total_cost', round(total_cost,2),
      'net', case when gl_income > 0 then round(gl_income-gl_costs,2)
                  else round(revenue-total_cost,2) end,
      'operating_ratio_pct', case when gl_income > 0 then round(gl_costs/gl_income*100,1)
                                  when revenue>0 then round(total_cost/revenue*100,1) end,
      'net_margin_pct', case when gl_income > 0 then round((gl_income-gl_costs)/gl_income*100,1)
                             when revenue>0 then round((revenue-total_cost)/revenue*100,1) end,
      'margin_basis', case when gl_income > 0
                           then format('GL (books), %s calendar months overlapping window', gl_months)
                           else 'operational tables — fuel history starts 2026-07-01, treat as partial' end,
      'contribution_margin', round(revenue-(fuel+tolls+driver_pay),2),
      'revenue_per_total_mile', case when total_mi>0 then round(revenue/total_mi,2) end,
      'revenue_per_loaded_mile', case when loaded_mi>0 then round(revenue/loaded_mi,2) end,
      'cost_per_total_mile', case when total_mi>0 then round(total_cost/total_mi,2) end,
      'fuel_cost_per_mile', case when total_mi>0 then round(fuel/total_mi,3) end,
      'maintenance_cost_per_mile', case when total_mi>0 then round(maint/total_mi,3) end,
      'driver_pay_pct_revenue', case when revenue>0 then round(driver_pay/revenue*100,1) end,
      'ar_outstanding', round(ar_out,2),
      'dso_days', case when revenue>0 then round(ar_out/(revenue/win_days),1) end,
      'bad_debt_pct', case when billed>0 then round(voided/billed*100,2) end,
      'detention_billable', round(det_pay,2)),
    'operations', jsonb_build_object(
      'loads', loads_n,
      'total_miles', total_mi, 'loaded_miles', loaded_mi, 'empty_miles', empty_mi,
      'eld_miles', round(coalesce(eld_mi,0),0),
      'empty_mile_pct', case when total_mi>0 then round(empty_mi/total_mi*100,1) end,
      'loaded_ratio_pct', case when total_mi>0 then round(loaded_mi/total_mi*100,1) end,
      'miles_per_tractor_per_week', case when active_trucks>0 then round(total_mi/active_trucks/weeks,0) end,
      'loads_per_tractor_per_week', case when active_trucks>0 then round(loads_n::numeric/active_trucks/weeks,2) end,
      'avg_length_of_haul', case when loads_n>0 then round(loaded_mi/loads_n,0) end,
      'trailer_to_tractor_ratio', case when active_trucks>0 then round(trailers_n::numeric/active_trucks,2) end,
      'fleet_mpg', case when eld_mpg is not null then eld_mpg
                        when gal>0 then round(loaded_mi/gal,2) end,
      'fleet_mpg_basis', case when eld_mpg is not null then 'ELD actual miles ÷ day-matched diesel gallons'
                              when gal>0 then 'booked loaded miles (no ELD coverage in window)' end,
      'on_time_delivery_pct', case when ot_meas>0 then round(ot_hit::numeric/ot_meas*100,1) end,
      'on_time_sample', ot_meas),
    'revenue', jsonb_build_object(
      'active_customers', customers_n,
      'avg_revenue_per_customer', case when customers_n>0 then round(revenue/customers_n,2) end,
      'top5_concentration_pct', case when revenue>0 then round(top5/revenue*100,1) end,
      'new_logo_revenue_pct', case when revenue>0 then round(newlogo/revenue*100,1) end,
      'rate_per_loaded_mile', case when loaded_mi>0 then round(revenue/loaded_mi,2) end),
    'sales', v_sales,
    'budget', (select jsonb_agg(to_jsonb(b)) from public.budget_variance(p_start, p_end) b),
    'insurance', public.insurance_snapshot(),
    'balance', public.gl_balance_ratios(),
    'safety', jsonb_build_object(
      'fmcsa_rating', case when s.safety_rating is null or s.safety_rating='' then 'Not rated' else public.fmcsa_rating_label(s.safety_rating) end,
      'allowed_to_operate', nullif(s.allowed_to_operate,''),
      'driver_oos_rate_pct', s.driver_oos_rate, 'driver_oos_national_pct', s.driver_oos_natl,
      'vehicle_oos_rate_pct', s.vehicle_oos_rate, 'vehicle_oos_national_pct', s.vehicle_oos_natl,
      'crashes_24mo', s.crash_total,
      'csa_basics_over_threshold', coalesce(csa_alerts,0),
      'accidents_in_window', coalesce(acc_n,0),
      'preventable_accidents_in_window', coalesce(prev_n,0),
      'out_of_service_events_in_window', coalesce(oos_n,0)),
    'detention', jsonb_build_object(
      'events', coalesce(det_events,0),
      'hours', round(coalesce(det_min,0)/60.0,1),
      'est_billable', round(coalesce(det_pay,0),2)),
    'telematics', jsonb_build_object(
      'eld_vehicles_connected', coalesce(veh_conn,0),
      'gps_live_2h', coalesce(gps_live,0),
      'drivers_hos_tracked', coalesce(drivers_tracked,0),
      'drivers_low_on_drive_hours', coalesce(low_hos,0),
      'idle_pct_30d', (public.idle_summary(30)->>'idle_pct')::numeric),
    'maintenance', jsonb_build_object(
      'avg_tractor_age_years', avg_tractor_age,
      'avg_trailer_age_years', avg_trailer_age,
      'maintenance_cost_per_mile', case when total_mi>0 then round(maint/total_mi,3) end),
    'systems', jsonb_build_object(
      'invoice_cycle_days', inv_cycle),
    'people', public.driver_turnover(p_start, p_end),
    'not_captured', jsonb_build_array(
      'telematics harsh-braking events'),
    'driver_nps', coalesce(
      (select to_jsonb(nps_row) from public.driver_nps_summary() nps_row
        order by nps_row.quarter desc limit 1),
      jsonb_build_object('status',
        'survey LIVE in the driver app since 2026-07-20 — no responses yet'))
  );
end;
$body$;

create or replace function public.finance_extras()
returns jsonb
language plpgsql security definer set search_path = public stable
as $$
declare out jsonb;
begin
  if auth.uid() is not null and public.my_role() not in ('admin', 'accountant') then
    raise exception 'Not enough permissions';
  end if;

  out := jsonb_build_object(
    -- #15 Accessorial Revenue (trailing 90d, invoiced)
    'accessorial_revenue_90d', coalesce((select sum(a.amount) from public.load_accessorials a
        where a.status = 'invoiced' and a.decided_at >= now() - interval '90 days'), 0),
    -- #71 Detention Capture Rate % — of proposals DECIDED in the window, the
    -- share the office captured (approved or invoiced) vs rejected. Undecided
    -- proposals are excluded (they're the review-queue nudge's job).
    'detention_capture_rate_pct', (select case when count(*) > 0
        then round(100.0 * count(*) filter (where a.status in ('approved','invoiced')) / count(*), 1)
        else null end
        from public.load_accessorials a
       where a.atype = 'detention' and a.status in ('approved','invoiced','rejected')
         and a.decided_at >= now() - interval '90 days'),
    -- #75 Billing Lag (days) — delivery → invoice, loads delivered last 90d
    'billing_lag_days', (select round(avg(extract(epoch from (i.invoice_date::timestamptz - l.delivery_time)) / 86400.0)::numeric, 1)
        from public.loads l join public.invoices i on i.id = l.invoice_id
       where l.delivery_time is not null and i.invoice_date is not null
         and i.status <> 'void'
         and l.delivery_time >= now() - interval '90 days'
         and i.invoice_date::timestamptz >= l.delivery_time),
    -- #41/#42/#43 AR aging past 45/60/90 days (open balance by invoice age)
    'ar_over_45', coalesce((select sum(public.invoice_balance(i)) from public.invoices i
        where i.status = 'sent' and i.factored_at is null and i.invoice_date < current_date - 45), 0),
    'ar_over_60', coalesce((select sum(public.invoice_balance(i)) from public.invoices i
        where i.status = 'sent' and i.factored_at is null and i.invoice_date < current_date - 60), 0),
    'ar_over_90', coalesce((select sum(public.invoice_balance(i)) from public.invoices i
        where i.status = 'sent' and i.factored_at is null and i.invoice_date < current_date - 90), 0),
    'as_of', now()
  );
  return out;
end;
$$;

revoke all on function public.finance_extras() from public, anon;
grant execute on function public.finance_extras() to authenticated, service_role;

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
      with ar as (select coalesce(sum(public.invoice_balance(i)),0) v from invoices i where i.status = 'sent' and i.factored_at is null),
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
      with ar as (select coalesce(sum(public.invoice_balance(i)),0) v from invoices i where i.status = 'sent' and i.factored_at is null),
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

create or replace function public.acct_summary()
returns jsonb language plpgsql security definer set search_path = public stable as $$
declare v_ar numeric; v_billed90 numeric; v_reserve numeric;
begin
  if public.my_role() <> 'admin' then raise exception 'Not enough permissions'; end if;
  select coalesce(sum(public.invoice_balance(i)),0) into v_ar
    from invoices i where i.status='sent' and i.factored_at is null;
  -- reserve NET of the factor's fee: the sliver left open on the books is
  -- the factor's cut, never arriving as cash
  select coalesce(sum(greatest(public.invoice_balance(i) - coalesce(i.factoring_fee,0), 0)),0) into v_reserve
    from invoices i where i.status='sent' and i.factored_at is not null;
  select coalesce(sum(total),0) into v_billed90
    from invoices where status<>'void' and invoice_date >= now()-interval '90 days';
  return jsonb_build_object(
    'ar_total', v_ar,
    'ar_past_due', (select coalesce(sum(public.invoice_balance(i)),0) from invoices i
                      where i.status='sent' and i.factored_at is null and i.due_date < now()),
    'past_due_count', (select count(*) from invoices where status='sent' and factored_at is null and due_date < now()),
    'open_count', (select count(*) from invoices where status='sent' and factored_at is null),
    'factoring_reserve', v_reserve,
    'factored_count', (select count(*) from invoices where factored_at is not null and status='sent'),
    'dso', case when v_billed90>0 then round(v_ar/v_billed90*90,1) end,
    'avg_days_to_pay', (select round(avg(extract(epoch from paid_at-invoice_date)/86400)::numeric,1)
                          from invoices where status='paid' and paid_at is not null
                            and invoice_date >= now()-interval '180 days'),
    'unbilled_total', (select coalesce(sum(rate),0) from loads where status='completed' and invoice_id is null),
    'unbilled_count', (select count(*) from loads where status='completed' and invoice_id is null),
    'mtd_billed', (select coalesce(sum(total),0) from invoices where status<>'void' and invoice_date >= date_trunc('month',now())),
    'mtd_collected', (select coalesce(sum(total - coalesce(factoring_fee,0)),0) from invoices where paid_at >= date_trunc('month',now()))
  );
end; $$;

revoke all on function public.acct_summary() from public, anon;
grant execute on function public.acct_summary() to authenticated, service_role;
