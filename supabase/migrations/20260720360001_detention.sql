-- Detention detection (Northstar; unblocked by geocoding). A driver held at a
-- shipper/receiver past the free time (industry standard ~2h) earns detention
-- pay (~$50/h) the broker owes — and it routinely goes unbilled because nobody
-- times it. Now that stops have coordinates and ELD gives GPS breadcrumbs, we
-- measure real dwell: the span of the assigned truck's breadcrumbs near the stop
-- around its appointment, minus free time.
--
-- Only fires where ELD coverage overlaps the stop's window (active/recent loads
-- now; more as breadcrumb history accumulates). Admin/dispatcher/accountant.

-- Great-circle miles between two lat/lon points (haversine).
create or replace function public.trux_miles(lat1 numeric, lon1 numeric, lat2 numeric, lon2 numeric)
returns numeric language sql immutable as $$
  select case
    when lat1 is null or lon1 is null or lat2 is null or lon2 is null then null
    else 3958.7559 * acos(least(1.0, greatest(-1.0,
      cos(radians(lat1)) * cos(radians(lat2)) * cos(radians(lon2) - radians(lon1))
      + sin(radians(lat1)) * sin(radians(lat2)))))
  end;
$$;

-- Detention events over the last p_days. p_free_min = free time before detention
-- accrues; p_rate = $/hour; p_radius_mi = how close a breadcrumb must be to count
-- as "at the stop".
create or replace function public.detention_events(
  p_days int default 45, p_free_min int default 120,
  p_rate numeric default 50, p_radius_mi numeric default 0.75)
returns table (
  load_id bigint, load_number text, customer text, stop_type text, stop_state text,
  appointment timestamptz, arrival timestamptz, departure timestamptz,
  dwell_min int, free_min int, detention_min int, est_pay numeric)
language plpgsql security definer set search_path = public stable as $$
begin
  if public.my_role() not in ('admin', 'dispatcher', 'accountant') then
    raise exception 'Not enough permissions';
  end if;
  return query
  with stops as (
    select l.id as load_id, l.load_number, c.company_name as customer, 'pickup'::text as stop_type,
           l.pickup_state as stop_state, l.pickup_time as appt, l.pickup_lat as lat, l.pickup_lon as lon, l.truck_id
      from public.loads l join public.customers c on c.id = l.customer_id
     where l.truck_id is not null and l.pickup_lat is not null and l.pickup_time is not null
       and l.delivery_time > now() - make_interval(days => p_days)
    union all
    select l.id, l.load_number, c.company_name, 'delivery',
           l.delivery_state, l.delivery_time, l.delivery_lat, l.delivery_lon, l.truck_id
      from public.loads l join public.customers c on c.id = l.customer_id
     where l.truck_id is not null and l.delivery_lat is not null and l.delivery_time is not null
       and l.delivery_time > now() - make_interval(days => p_days)
  ),
  dwell as (
    select s.*,
           (select min(h.ts) from public.eld_location_history h
             where h.truck_id = s.truck_id
               and h.ts between s.appt - interval '18 hours' and s.appt + interval '18 hours'
               and public.trux_miles(s.lat, s.lon, h.lat, h.lng) <= p_radius_mi) as arr,
           (select max(h.ts) from public.eld_location_history h
             where h.truck_id = s.truck_id
               and h.ts between s.appt - interval '18 hours' and s.appt + interval '18 hours'
               and public.trux_miles(s.lat, s.lon, h.lat, h.lng) <= p_radius_mi) as dep
      from stops s
  )
  select d.load_id, d.load_number, d.customer, d.stop_type, d.stop_state, d.appt, d.arr, d.dep,
         (extract(epoch from (d.dep - d.arr)) / 60)::int as dwell_min,
         p_free_min,
         greatest(0, (extract(epoch from (d.dep - d.arr)) / 60) - p_free_min)::int as detention_min,
         round(greatest(0, (extract(epoch from (d.dep - d.arr)) / 60) - p_free_min) / 60.0 * p_rate, 2) as est_pay
    from dwell d
   where d.arr is not null and d.dep is not null
     and (extract(epoch from (d.dep - d.arr)) / 60) > p_free_min
   order by detention_min desc;
end;
$$;
revoke all on function public.detention_events(int, int, numeric, numeric) from public, anon;
grant execute on function public.detention_events(int, int, numeric, numeric) to authenticated;
