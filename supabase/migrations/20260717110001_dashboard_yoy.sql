-- Dashboard v2.2: add same-week-last-year (to-date) comparison alongside the
-- week-over-week one. 364 days = exactly 52 weeks, so weekdays stay aligned.
-- Guard pattern must stay `is null or not in` — `not in` alone fails OPEN
-- for anonymous callers (my_role() is NULL).

create or replace function public.dashboard_summary()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  wk_start date := current_date - ((extract(isodow from current_date))::int - 1);
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
  -- same elapsed portion of this week, 52 weeks ago
  prev_yr_loads as (
    select * from done_loads
     where delivery_time >= (wk_start - 364)::timestamptz
       and delivery_time < (current_date - 363)::timestamptz
  )
  select jsonb_build_object(
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

-- Replacing a function preserves its ACL, but restate the lockdown so this
-- file is safe to apply standalone.
revoke execute on function public.dashboard_summary() from public, anon;
grant execute on function public.dashboard_summary() to authenticated;
