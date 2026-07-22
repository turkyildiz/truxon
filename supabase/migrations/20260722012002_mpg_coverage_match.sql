-- R8 Block 1 hotfix, caught on first live read: trucks whose ELD is dead or
-- spotty (unit 05 last reported 2026-01-10; unit 08 tracked 5 of 23 days)
-- contribute GALLONS but no MILES, so fleet MPG read 4.02 — physically absurd
-- for class-8 tractors. MPG must only count fuel bought on days the truck's
-- miles were actually banked ("tracked gallons"); untracked fuel still shows
-- in spend/gallons columns, it just can't pollute the efficiency ratio.

-- day-matched fleet aggregate; internal (definer callers only)
create or replace function public.eld_fleet_mpg(p_start date, p_end date)
returns table (eld_miles numeric, gallons_tracked numeric, mpg numeric)
language sql stable security definer set search_path = public
as $$
  with m as (
    select truck_id, day, sum(miles) as mi
      from eld_daily_miles
     where day >= p_start and day < p_end and truck_id is not null
     group by truck_id, day
  ), f as (
    select ft.truck_id, ft.transaction_time::date as day, sum(ft.gallons) as gal
      from fuel_transactions ft
     where ft.status <> 'Declined' and ft.truck_id is not null
       and ft.transaction_time >= p_start and ft.transaction_time < p_end
       and ft.fuel_type ilike '%diesel%' and ft.fuel_type not ilike '%exhaust%'
     group by ft.truck_id, ft.transaction_time::date
  ), covered as (
    -- a truck-day's fuel counts only if that truck banked ELD miles that day
    select f.truck_id, f.day, f.gal
      from f where exists (select 1 from m where m.truck_id = f.truck_id and m.day = f.day)
  )
  select round(coalesce((select sum(mi) from m), 0), 0),
         round(coalesce((select sum(gal) from covered), 0), 1),
         case when coalesce((select sum(gal) from covered), 0) > 0
              then round((select sum(mi) from m) / (select sum(gal) from covered), 2) end;
$$;
revoke all on function public.eld_fleet_mpg(date, date) from public, anon, authenticated;
grant execute on function public.eld_fleet_mpg(date, date) to service_role;

-- truck_mpg: per-truck tracked-gallons basis
create or replace function public.truck_mpg(p_days int default 30)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_start date := current_date - greatest(p_days, 1);
  v jsonb;
begin
  if public.my_role() not in ('admin','dispatcher','accountant') then
    raise exception 'Not enough permissions';
  end if;

  with em as (
    select truck_id, sum(miles) as mi, count(distinct day) as days_tracked
      from eld_daily_miles
     where day >= v_start and truck_id is not null
     group by truck_id
  ), fu_day as (
    select truck_id, transaction_time::date as day,
           sum(gallons) as gal,
           sum(coalesce(net_of_discount, amount)) as cost
      from fuel_transactions
     where status <> 'Declined' and truck_id is not null
       and transaction_time >= v_start
       and fuel_type ilike '%diesel%' and fuel_type not ilike '%exhaust%'
     group by truck_id, transaction_time::date
  ), fu as (
    select f.truck_id,
           sum(f.gal) as gal,
           sum(f.cost) as cost,
           -- gallons on days this truck's ELD banked miles — the honest MPG denominator
           sum(f.gal) filter (where exists (
             select 1 from eld_daily_miles e
              where e.truck_id = f.truck_id and e.day = f.day)) as gal_tracked
      from fu_day f
     group by f.truck_id
  ), per as (
    select t.id as truck_id, t.unit_number,
           round(coalesce(em.mi, 0), 0) as eld_miles,
           em.days_tracked,
           round(coalesce(fu.gal, 0), 1) as gallons,
           round(coalesce(fu.gal_tracked, 0), 1) as gallons_tracked,
           round(coalesce(fu.cost, 0), 2) as fuel_cost,
           case when coalesce(fu.gal_tracked, 0) >= 30 and coalesce(em.mi, 0) > 0
                then round(em.mi / fu.gal_tracked, 2) end as mpg,
           case when coalesce(em.mi, 0) > 0 and coalesce(fu.cost, 0) > 0
                then round(fu.cost / em.mi, 3) end as fuel_cost_per_mile
      from trucks t
      left join em on em.truck_id = t.id
      left join fu on fu.truck_id = t.id
     where t.status <> 'retired' and (em.mi > 0 or fu.gal > 0)
  ), wk_m as (
    select date_trunc('week', day)::date as week_start, sum(miles) as mi
      from eld_daily_miles
     where day >= v_start and truck_id is not null
     group by 1
  ), wk_f as (
    select date_trunc('week', f.day)::date as week_start, sum(f.gal) as gal
      from fu_day f
     where exists (select 1 from eld_daily_miles e
                    where e.truck_id = f.truck_id and e.day = f.day)
     group by 1
  ), wk as (
    select m.week_start, round(m.mi, 0) as miles,
           round(coalesce(f.gal, 0), 1) as gallons
      from wk_m m left join wk_f f on f.week_start = m.week_start
  )
  select jsonb_build_object(
    'window_days', p_days,
    'since', v_start,
    'fleet', (select jsonb_build_object(
        'eld_miles', coalesce(sum(eld_miles), 0),
        'gallons', coalesce(sum(gallons), 0),
        'gallons_tracked', coalesce(sum(gallons_tracked), 0),
        'fuel_cost', coalesce(sum(fuel_cost), 0),
        'mpg', case when coalesce(sum(gallons_tracked), 0) > 0
                    then round(sum(eld_miles) / sum(gallons_tracked), 2) end,
        'fuel_cost_per_mile', case when coalesce(sum(eld_miles), 0) > 0
                    then round(sum(fuel_cost) / sum(eld_miles), 3) end)
       from per),
    'trucks', (select coalesce(jsonb_agg(to_jsonb(p) order by p.mpg desc nulls last), '[]'::jsonb) from per p),
    'weekly', (select coalesce(jsonb_agg(jsonb_build_object(
        'week_start', w.week_start, 'miles', w.miles, 'gallons', w.gallons,
        'mpg', case when w.gallons > 0 then round(w.miles / w.gallons, 2) end)
        order by w.week_start), '[]'::jsonb) from wk w),
    'basis', 'ELD actual miles ÷ tracked diesel gallons (fuel on days the truck banked GPS miles); per-truck MPG suppressed under 30 tracked gal')
    into v;
  return v;
end;
$$;

-- scorecard: swap the fleet_mpg input to the day-matched aggregate.
-- (Surgical redefinition would be 300 lines again for two expressions; instead
-- the scorecard now reads eld_fleet_mpg() — declared above — for the ELD basis.)
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

update public.playbook_metrics
   set source = 'company_scorecard.operations.fleet_mpg — ELD actual miles ÷ day-matched diesel gallons (fuel only counts on GPS-covered truck-days); per-truck detail in truck_mpg()',
       updated_at = now()
 where number = 259;
