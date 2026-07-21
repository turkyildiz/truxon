-- Budget vs actual comes ALIVE: the budgets table existed since 20260719300002
-- but had no data — the owner never had to type a budget and never will:
-- ensure_auto_budget() seeds each month's missing lines from the trailing
-- 3-full-month actuals (marked basis='auto'; a manual row is never touched),
-- and a monthly cron keeps future months seeded. budget_variance's role gate
-- gets the standard auth.uid() prefix so the nightly capture (service path)
-- can read it. company_scorecard gains budget/insurance/balance sections and
-- not_captured shrinks to the two gaps that remain genuinely uncapturable.

alter table public.budgets add column if not exists basis text not null default 'manual'
  check (basis in ('manual', 'auto'));

create or replace function public.ensure_auto_budget(p_month date default date_trunc('month', now())::date)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_line text;
  v_avg numeric;
  v_added int := 0;
  m1 date := p_month - interval '3 months';
  pnl3 jsonb;
begin
  if auth.uid() is not null and public.my_role() not in ('admin', 'accountant') then
    raise exception 'Not enough permissions';
  end if;

  -- trailing 3 FULL months of actuals, one pnl call
  pnl3 := public.pnl_summary(m1::timestamptz, p_month::timestamptz);

  for v_line, v_avg in
    select * from (values
      ('revenue',     round((pnl3->>'revenue')::numeric / 3, 2)),
      ('fuel',        round((pnl3->>'fuel_cost')::numeric / 3, 2)),
      ('tolls',       round((pnl3->>'toll_cost')::numeric / 3, 2)),
      ('driver_pay',  round((pnl3->>'driver_pay')::numeric / 3, 2)),
      ('maintenance', round((pnl3->>'maintenance_cost')::numeric / 3, 2)),
      ('truck_fixed', round((pnl3->>'truck_fixed_cost')::numeric / 3, 2)),
      ('total_cost',  round((pnl3->>'total_cost')::numeric / 3, 2))
    ) t(line, avg_amt)
  loop
    if v_avg is not null and v_avg <> 0 then
      insert into budgets (period_month, line, amount, basis)
      values (p_month, v_line, v_avg, 'auto')
      on conflict (period_month, line) do nothing;
      if found then v_added := v_added + 1; end if;
    end if;
  end loop;
  return v_added;
end;
$$;
revoke all on function public.ensure_auto_budget(date) from public, anon;
grant execute on function public.ensure_auto_budget(date) to authenticated, service_role;

-- standard gate prefix: service/cron path (auth.uid() null) must pass
create or replace function public.budget_variance(p_start timestamptz, p_end timestamptz)
returns table (line text, budget numeric, actual numeric, variance numeric, variance_pct numeric)
language plpgsql stable security definer set search_path = public
as $fn$
declare pnl jsonb;
begin
  if auth.uid() is not null and public.my_role() not in ('admin','accountant','dispatcher') then
    raise exception 'Not enough permissions';
  end if;
  pnl := public.pnl_summary(p_start, p_end);
  return query
  with actuals(line, actual) as (
    values
      ('revenue', (pnl->>'revenue')::numeric),
      ('fuel', (pnl->>'fuel_cost')::numeric),
      ('tolls', (pnl->>'toll_cost')::numeric),
      ('driver_pay', (pnl->>'driver_pay')::numeric),
      ('maintenance', (pnl->>'maintenance_cost')::numeric),
      ('truck_fixed', (pnl->>'truck_fixed_cost')::numeric),
      ('total_cost', (pnl->>'total_cost')::numeric)
  ),
  budg as (
    select b.line, sum(b.amount) amt from public.budgets b
     where b.period_month >= date_trunc('month', p_start)::date
       and b.period_month < p_end::date
     group by b.line
  )
  select a.line, coalesce(bu.amt,0), a.actual,
         round(a.actual - coalesce(bu.amt,0), 2),
         case when coalesce(bu.amt,0) <> 0 then round((a.actual - bu.amt)/bu.amt*100, 1) end
    from actuals a left join budg bu on bu.line = a.line
   order by case a.line when 'revenue' then 0 when 'total_cost' then 9 else 5 end, a.line;
end;
$fn$;
revoke execute on function public.budget_variance(timestamptz, timestamptz) from public, anon;
grant execute on function public.budget_variance(timestamptz, timestamptz) to authenticated, service_role;

-- monthly cron: seed the new month's auto-budget on the 1st (and catch-up now)
do $$ begin perform cron.unschedule('truxon-budget-seed'); exception when others then null; end $$;
select cron.schedule('truxon-budget-seed', '35 2 1 * *',
  $$select public.ensure_auto_budget()$$);
select public.ensure_auto_budget();

-- company_scorecard: budget/insurance/balance sections + honest not_captured
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
  select coalesce(sum(total),0) into ar_out from public.invoices where status='sent';
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
      'drivers_low_on_drive_hours', coalesce(low_hos,0)),
    'maintenance', jsonb_build_object(
      'avg_tractor_age_years', avg_tractor_age,
      'avg_trailer_age_years', avg_trailer_age,
      'maintenance_cost_per_mile', case when total_mi>0 then round(maint/total_mi,3) end),
    'systems', jsonb_build_object(
      'invoice_cycle_days', inv_cycle),
    'not_captured', jsonb_build_array(
      'telematics harsh-braking & idle events', 'driver turnover/NPS')
  );
end;
$$;

revoke execute on function public.company_scorecard(timestamptz, timestamptz) from public, anon;
grant execute on function public.company_scorecard(timestamptz, timestamptz) to authenticated;
