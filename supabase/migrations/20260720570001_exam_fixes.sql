-- Forest final-exam fixes (2026-07-20 overnight run #2, item 1):
-- 1. customer_pay_profile() gains the customer NAME — exam answers cited bare
--    IDs ("customer 211") because the profile had no name column. All consumers
--    (slow_pay_risk, cashflow_forecast, sentinel) reference columns by name.
-- 2. company_scorecard: financial.ar_outstanding / dso_days used sum(total) on
--    sent invoices — $483K where true outstanding is $156K. Now invoice_balance().
--    (weekly_flash and acct_summary were already outstanding-based; the exam
--    caught the scorecard contradicting them.)
-- company_scorecard reproduced WHOLE from 20260720560001 (splice discipline).

drop function if exists public.customer_pay_profile();
create function public.customer_pay_profile()
returns table (customer_id bigint, customer text, avg_days numeric, paid_count int)
language sql security definer set search_path = public stable as $$
  select i.customer_id,
         c.company_name,
         round(avg(extract(epoch from (i.paid_at - i.invoice_date)) / 86400.0)::numeric, 1),
         count(*)::int
  from public.invoices i
  join public.customers c on c.id = i.customer_id
  where i.status = 'paid' and i.paid_at is not null
    and i.invoice_date > now() - interval '365 days'
  group by i.customer_id, c.company_name;
$$;
revoke all on function public.customer_pay_profile() from public, anon;
grant execute on function public.customer_pay_profile() to authenticated, service_role;

create or replace function public.company_scorecard(p_start timestamptz, p_end timestamptz)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
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
  -- newly-captured (Northstar night)
  det_events int; det_min numeric; det_pay numeric;
  s record; csa_alerts int; acc_n int; prev_n int; oos_n int;
  veh_conn int; gps_live int; drivers_tracked int; low_hos int;
  ot_meas int; ot_hit int;
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

  -- AR / bad debt
  -- OUTSTANDING balance, not face total: QBO-mirror invoices carry factoring-fee
  -- residuals and partial payments; sum(total) overstated open AR ~3x (exam find).
  select coalesce(sum(public.invoice_balance(i)),0) into ar_out from public.invoices i where i.status='sent';
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
      'net', round(revenue-total_cost,2),
      'operating_ratio_pct', case when revenue>0 then round(total_cost/revenue*100,1) end,
      'net_margin_pct', case when revenue>0 then round((revenue-total_cost)/revenue*100,1) end,
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
      'empty_mile_pct', case when total_mi>0 then round(empty_mi/total_mi*100,1) end,
      'loaded_ratio_pct', case when total_mi>0 then round(loaded_mi/total_mi*100,1) end,
      'miles_per_tractor_per_week', case when active_trucks>0 then round(total_mi/active_trucks/weeks,0) end,
      'loads_per_tractor_per_week', case when active_trucks>0 then round(loads_n::numeric/active_trucks/weeks,2) end,
      'avg_length_of_haul', case when loads_n>0 then round(loaded_mi/loads_n,0) end,
      'trailer_to_tractor_ratio', case when active_trucks>0 then round(trailers_n::numeric/active_trucks,2) end,
      'fleet_mpg', case when gal>0 then round(loaded_mi/gal,2) end,
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
      'telematics harsh-braking events', 'driver NPS')
  );
end;
$$;

-- 3. fleet_cost_basis rebuilt — the exam caught it reporting 28.65 MPG and a
--    $0.85 break-even on the live Dispatch margin panel. Root causes:
--    (a) MPG divided 90 days of load-miles by fuel that only exists since
--        2026-07-01 (AtoB backfill start) — now computed over the overlap
--        window only, on TOTAL miles (deadhead burns fuel too);
--    (b) fixed_per_mile read trucks.monthly_cost (all zeros on prod) — now the
--        break-even anchors to the BOOKS: GL all-in cost per total mile over
--        the trailing 3 full months, with fixed = residual after fuel/pay/toll.
--    Old return keys unchanged; adds gl_all_in_rpm, basis, fuel_data_from.
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
  v_basis text := 'components';
begin
  if public.my_role() not in ('admin', 'dispatcher', 'accountant') then
    raise exception 'Not enough permissions';
  end if;

  -- MPG over the window where fuel data actually exists (max 90d back)
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

  -- The books' all-in cost per total mile, trailing 3 FULL months
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

  if v_gl_rpm is not null then
    -- Anchor break-even to the books; fixed = what's left after direct components
    v_basis := 'gl';
    v_breakeven := round(v_gl_rpm, 2);
    v_fixed_per_mile := greatest(round(v_gl_rpm - v_fuel_price / nullif(v_mpg, 0) - v_pay - v_toll_per_mile, 3), 0);
  else
    -- No GL mirror: old component build-up, trucks.monthly_cost when populated
    select coalesce(sum(monthly_cost), 0) / 4.33 into v_fixed_wk from public.trucks where status <> 'retired';
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
    'fuel_data_from', v_fuel_lo::date);
end;
$$;
revoke all on function public.fleet_cost_basis() from public, anon;
grant execute on function public.fleet_cost_basis() to authenticated;
