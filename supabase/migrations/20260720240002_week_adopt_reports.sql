-- Adopt the standard week (20260720240001) across the two functions that define
-- a "week": dashboard_summary and weekly_report. Everything else that talks about
-- weeks (Sentinel's "at a loss this week", exec reports' driver-pay) calls
-- weekly_report() and inherits it — no separate week math anywhere else.
--
-- Changes are surgical: week boundaries now come from trux_week_start/end (so a
-- year's partial first week is Week 0, clamped to Jan 1), each payload carries a
-- 'week_number'/'week_label', and the dashboard's same-week-last-year comparison
-- is anchored by WEEK NUMBER (Week N ↔ Week N) instead of a rolling 364 days.
-- All business logic below is otherwise unchanged.

-- ── weekly_report ─────────────────────────────────────────────────────────────
create or replace function public.weekly_report(p_week_of date default current_date)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  wk_start date := public.trux_week_start(p_week_of);
  wk_end date := public.trux_week_end(p_week_of);
  wk_from timestamptz := wk_start::timestamptz;
  wk_to timestamptz := (wk_end + 1)::timestamptz;
  result jsonb;
begin
  if public.my_role() is null or public.my_role() not in ('admin', 'accountant', 'dispatcher') then
    raise exception 'Not enough permissions';
  end if;

  with wk_loads as (
    select l.* from public.loads l
     where l.status in ('completed', 'billed')
       and l.delivery_time >= wk_from
       and l.delivery_time < wk_to
  ),
  fuel_wk as (
    select f.truck_id,
           sum(coalesce(f.net_of_discount, f.amount)) as fuel_cost,
           coalesce(sum(f.gallons), 0) as fuel_gallons
      from public.fuel_transactions f
     where f.truck_id is not null
       and f.status <> 'Declined'
       and f.transaction_time >= wk_from
       and f.transaction_time < wk_to
     group by f.truck_id
  ),
  by_truck as (
    select t.id as key_id, t.unit_number as name,
           count(*)::int as loads, sum(w.miles) as miles, sum(w.rate) as revenue,
           case when sum(w.miles) > 0 then round(sum(w.rate) / sum(w.miles), 2) end as avg_rate_per_mile,
           round(coalesce(fw.fuel_cost, 0), 2) as fuel_cost,
           coalesce(fw.fuel_gallons, 0) as fuel_gallons,
           case when coalesce(fw.fuel_gallons, 0) > 0 then round(sum(w.miles) / fw.fuel_gallons, 2) end as mpg,
           round(sum(w.rate) - coalesce(fw.fuel_cost, 0), 2) as net_after_fuel
      from wk_loads w
      join public.trucks t on t.id = w.truck_id
      left join fuel_wk fw on fw.truck_id = t.id
     group by t.id, t.unit_number, fw.fuel_cost, fw.fuel_gallons
  ),
  by_driver as (
    select d.id as key_id, d.full_name as name,
           count(*)::int as loads, sum(w.miles) as miles, sum(w.rate) as revenue,
           sum(w.empty_miles) as empty_miles,
           case when sum(w.miles) > 0 then round(sum(w.rate) / sum(w.miles), 2) end as avg_rate_per_mile,
           round(sum(w.miles) * d.pay_per_mile
                 + case when d.empty_miles_paid then coalesce(sum(w.empty_miles), 0) * d.pay_per_empty_mile else 0 end,
             2) as driver_pay
      from wk_loads w join public.drivers d on d.id = w.driver_id
     group by d.id, d.full_name, d.pay_per_mile, d.pay_per_empty_mile, d.empty_miles_paid
  ),
  -- All fuel spend in the week (including transactions not matched to a truck),
  -- so the company-level P&L total is complete.
  fuel_total as (
    select coalesce(sum(coalesce(net_of_discount, amount)), 0) as fuel_cost,
           coalesce(sum(gallons), 0) as fuel_gallons
      from public.fuel_transactions
     where status <> 'Declined' and transaction_time >= wk_from and transaction_time < wk_to
  )
  select jsonb_build_object(
    'week_start', wk_start,
    'week_end', wk_end,
    'week_number', public.trux_week_number(p_week_of),
    'week_year', public.trux_week_year(p_week_of),
    'week_label', public.trux_week_label(p_week_of),
    'by_truck', coalesce((select jsonb_agg(to_jsonb(bt) order by bt.revenue desc) from by_truck bt), '[]'::jsonb),
    'by_driver', coalesce((select jsonb_agg(to_jsonb(bd) order by bd.revenue desc) from by_driver bd), '[]'::jsonb),
    'totals', (select jsonb_build_object(
        'loads', count(*)::int,
        'miles', coalesce(sum(w.miles), 0),
        'revenue', coalesce(sum(w.rate), 0),
        'avg_rate_per_mile', case when coalesce(sum(w.miles), 0) > 0 then round(sum(w.rate) / sum(w.miles), 2) end,
        'fuel_cost', (select round(fuel_cost, 2) from fuel_total),
        'fuel_gallons', (select fuel_gallons from fuel_total),
        'net_after_fuel', round(coalesce(sum(w.rate), 0) - (select fuel_cost from fuel_total), 2),
        'fuel_pct_of_revenue', case when coalesce(sum(w.rate), 0) > 0
          then round((select fuel_cost from fuel_total) / sum(w.rate) * 100, 1) end
      ) from wk_loads w)
  ) into result;
  return result;
end;
$$;

revoke execute on function public.weekly_report(date) from public, anon;
grant execute on function public.weekly_report(date) to authenticated;

-- ── dashboard_summary ─────────────────────────────────────────────────────────
create or replace function public.dashboard_summary()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  wk_start date := public.trux_week_start(current_date);
  wk_num int := public.trux_week_number(current_date);
  wk_lbl text := public.trux_week_label(current_date);
  -- same week number, last year: the Nth Monday-started block a year ago
  ly_start date := (select week_start from public.trux_week_range(
                      public.trux_week_year(current_date) - 1, public.trux_week_number(current_date)));
  result jsonb;
begin
  if public.my_role() is null or public.my_role() not in ('admin', 'dispatcher', 'accountant') then
    raise exception 'Not enough permissions';
  end if;

  with done_loads as (
    select * from public.loads where status in ('completed', 'billed')
  ),
  wk_loads as (
    select * from done_loads
     where delivery_time >= wk_start::timestamptz
       and delivery_time < (wk_start + 7)::timestamptz
  ),
  -- same elapsed portion of last week: Monday through this weekday
  prev_wk_loads as (
    select * from done_loads
     where delivery_time >= (wk_start - 7)::timestamptz
       and delivery_time < (current_date - 6)::timestamptz
  ),
  -- same elapsed portion of Week N last year (anchored by week number, so the
  -- weekdays line up): last year's Monday through the same number of days in
  prev_yr_loads as (
    select * from done_loads
     where delivery_time >= ly_start::timestamptz
       and delivery_time < (ly_start + (current_date - wk_start) + 1)::timestamptz
  )
  select jsonb_build_object(
    'week_number', wk_num,
    'week_label', wk_lbl,
    'week_start', wk_start,
    'week_revenue', (select coalesce(sum(rate), 0) from wk_loads),
    'week_miles', (select coalesce(sum(miles), 0) from wk_loads),
    'week_loads', (select count(*)::int from wk_loads),
    'week_avg_rate_per_mile', (select case when coalesce(sum(miles), 0) > 0 then round(sum(rate) / sum(miles), 2) end from wk_loads),
    'prev_week', (select jsonb_build_object(
        'revenue', coalesce(sum(rate), 0),
        'miles', coalesce(sum(miles), 0),
        'loads', count(*)::int,
        'avg_rate_per_mile', case when coalesce(sum(miles), 0) > 0 then round(sum(rate) / sum(miles), 2) end
      ) from prev_wk_loads),
    'prev_year_week', (select jsonb_build_object(
        'label', public.trux_week_label(ly_start),
        'revenue', coalesce(sum(rate), 0),
        'miles', coalesce(sum(miles), 0),
        'loads', count(*)::int,
        'avg_rate_per_mile', case when coalesce(sum(miles), 0) > 0 then round(sum(rate) / sum(miles), 2) end
      ) from prev_yr_loads),
    'available_trucks', (select count(*)::int from public.trucks where status = 'available'),
    'active_drivers', (select count(*)::int from public.drivers where status = 'active'),
    'status_counts', (select coalesce(jsonb_object_agg(status, n), '{}'::jsonb)
                        from (select status, count(*)::int as n from public.loads group by status) s),
    'revenue_by_day', (select jsonb_agg(jsonb_build_object(
                          'day', to_char(d.day, 'Dy'),
                          'revenue', coalesce((select sum(rate) from wk_loads w where w.delivery_time::date = d.day), 0))
                          order by d.day)
                         from generate_series(wk_start, wk_start + 6, interval '1 day') as d(day)),
    'trend_weekly', (select jsonb_agg(jsonb_build_object(
                        'label', to_char(w.week, 'Mon DD'),
                        'week', public.trux_week_label(w.week::date),
                        'revenue', coalesce(t.revenue, 0),
                        'miles', coalesce(t.miles, 0),
                        'empty_miles', coalesce(t.empty_miles, 0),
                        'loads', coalesce(t.loads, 0)) order by w.week)
                       from generate_series(wk_start - 77, wk_start, interval '7 days') as w(week)
                       left join (
                         select date_trunc('week', delivery_time)::date as week,
                                sum(rate) as revenue, sum(miles) as miles,
                                sum(coalesce(empty_miles, 0)) as empty_miles, count(*)::int as loads
                           from done_loads
                          where delivery_time >= (wk_start - 77)::timestamptz
                          group by 1
                       ) t on t.week = w.week::date),
    'trend_monthly', (select jsonb_agg(jsonb_build_object(
                        'label', to_char(m.month, 'Mon'),
                        'revenue', coalesce(t.revenue, 0),
                        'miles', coalesce(t.miles, 0),
                        'empty_miles', coalesce(t.empty_miles, 0),
                        'loads', coalesce(t.loads, 0)) order by m.month)
                       from generate_series(date_trunc('month', current_date) - interval '11 months',
                                            date_trunc('month', current_date), interval '1 month') as m(month)
                       left join (
                         select date_trunc('month', delivery_time)::date as month,
                                sum(rate) as revenue, sum(miles) as miles,
                                sum(coalesce(empty_miles, 0)) as empty_miles, count(*)::int as loads
                           from done_loads
                          where delivery_time >= date_trunc('month', current_date) - interval '11 months'
                          group by 1
                       ) t on t.month = m.month::date),
    'top_customers', coalesce((select jsonb_agg(to_jsonb(tc) order by tc.revenue desc) from (
                        select c.company_name as name, sum(l.rate) as revenue, count(*)::int as loads
                          from done_loads l join public.customers c on c.id = l.customer_id
                         where l.delivery_time >= (current_date - 90)::timestamptz
                         group by c.company_name
                         order by 2 desc limit 6
                      ) tc), '[]'::jsonb),
    'driver_perf', coalesce((select jsonb_agg(to_jsonb(dp) order by dp.miles desc) from (
                        select d.full_name as name, sum(l.miles) as miles,
                               sum(l.rate) as revenue, count(*)::int as loads
                          from done_loads l join public.drivers d on d.id = l.driver_id
                         where l.delivery_time >= (current_date - 30)::timestamptz
                         group by d.full_name
                         order by 2 desc limit 6
                      ) dp), '[]'::jsonb),
    'expiring_licenses', coalesce((select jsonb_agg(to_jsonb(d)) from (
                            select id, full_name, license_expiration from public.drivers
                             where status = 'active' and license_expiration is not null
                               and license_expiration <= current_date + 30
                          ) d), '[]'::jsonb),
    'active_loads', coalesce((select jsonb_agg(to_jsonb(al) order by al.pickup_time) from (
                        select l.id, l.load_number, l.status, l.pickup_address, l.pickup_time,
                               l.delivery_address, l.delivery_time,
                               c.company_name as customer_name, d.full_name as driver_name
                          from public.loads l
                          join public.customers c on c.id = l.customer_id
                          left join public.drivers d on d.id = l.driver_id
                         where l.status in ('assigned', 'in_transit')
                         limit 25
                      ) al), '[]'::jsonb)
  ) into result;
  return result;
end;
$$;

revoke execute on function public.dashboard_summary() from public, anon;
grant execute on function public.dashboard_summary() to authenticated;
