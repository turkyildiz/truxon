-- R9 #134/#137: per-customer one-pagers.
-- #134 customer_qbr: this quarter vs last — loads, revenue, $/mi, cancels,
--   payment speed, top lanes. Facts a QBR call needs, nothing invented.
-- #137 customer_detention_profile: THEIR facilities' measured dwell (GPS
--   geofence dwell, same method as detention_events) turned into a policy
--   paragraph — "your docks average Xh, N% blow past 2h free time" — with
--   unmeasured stops counted, never hidden.
create or replace function public.customer_qbr(p_customer_id bigint)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v jsonb;
  q_start date := date_trunc('quarter', now())::date;
  pq_start date := (date_trunc('quarter', now()) - interval '3 months')::date;
begin
  if not (coalesce(auth.role(), '') = 'service_role'
          or public.my_role() in ('admin','dispatcher','accountant')) then
    raise exception 'Not enough permissions';
  end if;
  with lq as (
    select case when l.created_at >= q_start then 'cur' else 'prev' end as q, l.*
      from loads l
     where l.customer_id = p_customer_id and l.created_at >= pq_start
  ), agg as (
    select q,
           count(*) filter (where status <> 'cancelled') as loads_n,
           count(*) filter (where status = 'cancelled') as cancels,
           round(sum(rate) filter (where status <> 'cancelled'), 2) as revenue,
           round(avg(rate) filter (where status <> 'cancelled'), 0) as avg_rate,
           round((sum(rate) filter (where status <> 'cancelled'))
                 / nullif(sum(miles) filter (where status <> 'cancelled' and miles > 0), 0), 2) as rpm
      from lq group by q
  ), pay as (
    select round(avg(extract(epoch from (i.paid_at - i.invoice_date)) / 86400.0), 0) as avg_days_to_pay,
           count(*) filter (where i.status = 'paid') as paid_n,
           count(*) filter (where i.status = 'sent') as open_n,
           round(sum(i.total) filter (where i.status = 'sent'), 2) as open_total
      from invoices i
     where i.customer_id = p_customer_id
       and i.invoice_date > now() - interval '183 days'
  )
  select jsonb_build_object(
    'customer', (select company_name from customers where id = p_customer_id),
    'quarter_start', q_start,
    'current', (select to_jsonb(a) - 'q' from agg a where a.q = 'cur'),
    'previous', (select to_jsonb(a) - 'q' from agg a where a.q = 'prev'),
    'payment', (select to_jsonb(p) from pay p),
    'top_lanes', coalesce((select jsonb_agg(jsonb_build_object(
        'lane', x.lane, 'loads', x.n, 'revenue', x.rev) order by x.rev desc)
      from (select coalesce(nullif(pickup_state,''),'?')||'→'||coalesce(nullif(delivery_state,''),'?') as lane,
                   count(*) n, round(sum(rate), 0) rev
              from lq where status <> 'cancelled' and q = 'cur'
             group by 1 order by 3 desc limit 5) x), '[]'::jsonb),
    'note', 'quarters are calendar quarters by booking date; payment speed over the trailing 6 months of invoices',
    'as_of', now()) into v;
  return v;
end;
$$;
revoke all on function public.customer_qbr(bigint) from public, anon, authenticated;
grant execute on function public.customer_qbr(bigint) to authenticated, service_role;

create or replace function public.customer_detention_profile(
  p_customer_id bigint, p_days int default 180,
  p_free_min int default 120, p_rate numeric default 50)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare v jsonb;
begin
  if not (coalesce(auth.role(), '') = 'service_role'
          or public.my_role() in ('admin','dispatcher','accountant')) then
    raise exception 'Not enough permissions';
  end if;
  with stops as (
    select l.id, l.load_number, 'pickup'::text as stop_type, l.pickup_address as facility,
           l.pickup_time as appt, l.pickup_lat as lat, l.pickup_lon as lon, l.truck_id
      from loads l
     where l.customer_id = p_customer_id and l.pickup_time is not null
       and l.created_at > now() - make_interval(days => p_days) and l.status <> 'cancelled'
    union all
    select l.id, l.load_number, 'delivery', l.delivery_address,
           l.delivery_time, l.delivery_lat, l.delivery_lon, l.truck_id
      from loads l
     where l.customer_id = p_customer_id and l.delivery_time is not null
       and l.created_at > now() - make_interval(days => p_days) and l.status <> 'cancelled'
  ), dwell as (
    select s.*,
           case when s.lat is null or s.truck_id is null then null else
             (select extract(epoch from (max(h.ts) - min(h.ts))) / 60
                from eld_location_history h
               where h.truck_id = s.truck_id
                 and h.ts between s.appt - interval '18 hours' and s.appt + interval '18 hours'
                 and public.trux_miles(s.lat, s.lon, h.lat, h.lng) <= 0.75)
           end as dwell_min
      from stops s
  ), m as (select * from dwell where dwell_min is not null and dwell_min > 0)
  select jsonb_build_object(
    'customer', (select company_name from customers where id = p_customer_id),
    'days', p_days, 'free_min', p_free_min, 'rate_per_hour', p_rate,
    'stops_total', (select count(*) from stops),
    'stops_measured', (select count(*) from m),
    'avg_dwell_min', (select round(avg(dwell_min)::numeric, 0) from m),
    'median_dwell_min', (select round((percentile_cont(0.5) within group (order by dwell_min))::numeric, 0) from m),
    'pct_over_free', (select round(100.0 * count(*) filter (where dwell_min > p_free_min) / nullif(count(*), 0), 0) from m),
    'detention_hours', (select round(sum(greatest(0, dwell_min - p_free_min)) / 60.0, 1) from m),
    'est_owed', (select round(sum(greatest(0, dwell_min - p_free_min)) / 60.0 * p_rate, 2) from m),
    'worst_facilities', coalesce((select jsonb_agg(jsonb_build_object(
        'facility', w.facility, 'stop_type', w.stop_type, 'stops', w.n,
        'avg_dwell_min', w.avg_dw) order by w.avg_dw desc)
      from (select facility, stop_type, count(*) n, round(avg(dwell_min)::numeric, 0) avg_dw
              from m group by facility, stop_type
            having count(*) >= 2 order by avg(dwell_min) desc limit 5) w), '[]'::jsonb),
    'note', 'dwell = GPS geofence time within 0.75mi of the stop (18h window); stops without GPS coverage are counted in stops_total but not measured',
    'as_of', now()) into v;
  return v;
end;
$$;
revoke all on function public.customer_detention_profile(bigint, int, int, numeric) from public, anon, authenticated;
grant execute on function public.customer_detention_profile(bigint, int, int, numeric) to authenticated, service_role;
