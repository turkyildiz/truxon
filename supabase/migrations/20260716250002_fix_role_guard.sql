-- Fix regression from 20260716250001: my_role() returns the user_role ENUM,
-- so `coalesce(my_role(), '')` fails ("invalid input value for enum ... ''").
-- Use an explicit NULL check instead — same NULL-safe intent, valid types.
-- (Execution is already revoked from anon in the prior migration; this keeps
-- the in-function guard correct for authenticated callers.)

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

  with wk_loads as (
    select * from public.loads
     where status in ('completed', 'billed')
       and delivery_time >= wk_start::timestamptz
       and delivery_time < (wk_start + 7)::timestamptz
  )
  select jsonb_build_object(
    'week_revenue', (select coalesce(sum(rate), 0) from wk_loads),
    'week_miles', (select coalesce(sum(miles), 0) from wk_loads),
    'week_loads', (select count(*)::int from wk_loads),
    'week_avg_rate_per_mile', (select case when coalesce(sum(miles), 0) > 0 then round(sum(rate) / sum(miles), 2) end from wk_loads),
    'available_trucks', (select count(*)::int from public.trucks where status = 'available'),
    'active_drivers', (select count(*)::int from public.drivers where status = 'active'),
    'status_counts', (select coalesce(jsonb_object_agg(status, n), '{}'::jsonb)
                        from (select status, count(*)::int as n from public.loads group by status) s),
    'revenue_by_day', (select jsonb_agg(jsonb_build_object(
                          'day', to_char(d.day, 'Dy'),
                          'revenue', coalesce((select sum(rate) from wk_loads w where w.delivery_time::date = d.day), 0))
                          order by d.day)
                         from generate_series(wk_start, wk_start + 6, interval '1 day') as d(day)),
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

create or replace function public.global_search(q text)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if public.my_role() is null or public.my_role() not in ('admin', 'dispatcher', 'accountant') then
    raise exception 'Not enough permissions';
  end if;
  return jsonb_build_object(
    'loads', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'label', l.load_number || ' — ' || c.company_name))
                from (select * from public.loads
                       where load_number ilike '%' || q || '%'
                          or reference_number ilike '%' || q || '%'
                          or pickup_address ilike '%' || q || '%'
                          or delivery_address ilike '%' || q || '%' limit 10) l
                join public.customers c on c.id = l.customer_id), '[]'::jsonb),
    'customers', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'label', company_name))
                    from (select id, company_name from public.customers where company_name ilike '%' || q || '%' limit 10) c), '[]'::jsonb),
    'drivers', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'label', full_name))
                  from (select id, full_name from public.drivers where full_name ilike '%' || q || '%' limit 10) d), '[]'::jsonb),
    'trucks', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'label', unit_number))
                 from (select id, unit_number from public.trucks where unit_number ilike '%' || q || '%' limit 10) t), '[]'::jsonb)
  );
end;
$$;

create or replace function public.weekly_report(p_week_of date default current_date)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  wk_start date := p_week_of - ((extract(isodow from p_week_of))::int - 1);
  wk_end date := wk_start + 6;
  result jsonb;
begin
  if public.my_role() is null or public.my_role() not in ('admin', 'accountant', 'dispatcher') then
    raise exception 'Not enough permissions';
  end if;

  with wk_loads as (
    select l.* from public.loads l
     where l.status in ('completed', 'billed')
       and l.delivery_time >= wk_start::timestamptz
       and l.delivery_time < (wk_end + 1)::timestamptz
  ),
  by_truck as (
    select t.id as key_id, t.unit_number as name,
           count(*)::int as loads, sum(w.miles) as miles, sum(w.rate) as revenue,
           case when sum(w.miles) > 0 then round(sum(w.rate) / sum(w.miles), 2) end as avg_rate_per_mile
      from wk_loads w join public.trucks t on t.id = w.truck_id
     group by t.id, t.unit_number
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
  )
  select jsonb_build_object(
    'week_start', wk_start,
    'week_end', wk_end,
    'by_truck', coalesce((select jsonb_agg(to_jsonb(bt) order by bt.revenue desc) from by_truck bt), '[]'::jsonb),
    'by_driver', coalesce((select jsonb_agg(to_jsonb(bd) order by bd.revenue desc) from by_driver bd), '[]'::jsonb),
    'totals', (select jsonb_build_object(
        'loads', count(*)::int,
        'miles', coalesce(sum(miles), 0),
        'revenue', coalesce(sum(rate), 0),
        'avg_rate_per_mile', case when coalesce(sum(miles), 0) > 0 then round(sum(rate) / sum(miles), 2) end
      ) from wk_loads)
  ) into result;
  return result;
end;
$$;

grant execute on function public.dashboard_summary() to authenticated;
grant execute on function public.global_search(text) to authenticated;
grant execute on function public.weekly_report(date) to authenticated;
revoke execute on function public.dashboard_summary() from public, anon;
revoke execute on function public.global_search(text) from public, anon;
revoke execute on function public.weekly_report(date) from public, anon;
