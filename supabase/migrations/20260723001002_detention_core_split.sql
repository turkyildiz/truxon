-- Companion to 20260723001001_positive_role_gates: the gate fix exposed a latent bug.
-- my_week_scorecard (driver-facing, SECURITY DEFINER) called the office-gated
-- detention_events; drivers only got through via the NULL-auth.role() loophole locally,
-- and would be denied in prod where auth.role() = 'authenticated'.
-- Split the computation into detention_events_core (not callable by app roles) and keep
-- the office gate on the public detention_events wrapper. my_week_scorecard (definer:
-- postgres) calls the core directly and still returns only the calling driver's loads.

CREATE OR REPLACE FUNCTION public.detention_events_core(p_days integer DEFAULT 45, p_free_min integer DEFAULT 120, p_rate numeric DEFAULT 50, p_radius_mi numeric DEFAULT 0.75)
 RETURNS TABLE(load_id bigint, load_number text, customer text, stop_type text, stop_state text, appointment timestamp with time zone, arrival timestamp with time zone, departure timestamp with time zone, dwell_min integer, free_min integer, detention_min integer, est_pay numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
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
$function$;

revoke execute on function public.detention_events_core(integer, integer, numeric, numeric) from public, anon, authenticated;
grant execute on function public.detention_events_core(integer, integer, numeric, numeric) to service_role;

CREATE OR REPLACE FUNCTION public.detention_events(p_days integer DEFAULT 45, p_free_min integer DEFAULT 120, p_rate numeric DEFAULT 50, p_radius_mi numeric DEFAULT 0.75)
 RETURNS TABLE(load_id bigint, load_number text, customer text, stop_type text, stop_state text, appointment timestamp with time zone, arrival timestamp with time zone, departure timestamp with time zone, dwell_min integer, free_min integer, detention_min integer, est_pay numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not (coalesce(auth.role(), '') = 'service_role' or public.my_role() in ('admin', 'dispatcher', 'accountant')) then
    raise exception 'Not enough permissions';
  end if;
  return query
  select * from public.detention_events_core(p_days, p_free_min, p_rate, p_radius_mi);
end;
$function$;

CREATE OR REPLACE FUNCTION public.my_week_scorecard(p_week_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  ws date := public.trux_week_start(current_date) - (7 * greatest(p_week_offset, 0));
  we date;
  v_days_back int;
  v_driver_id bigint;
  v_row jsonb;
begin
  select d.id into v_driver_id from drivers d where d.user_id = auth.uid();
  if v_driver_id is null then
    return null;  -- office user or unlinked login: no card
  end if;
  we := ws + 7;
  v_days_back := greatest((current_date - ws)::int + 1, 1);

  select to_jsonb(t) into v_row from (
    with wk_loads as (
      select l.* from loads l
       where l.status in ('completed', 'billed')
         and l.delivery_time >= ws and l.delivery_time < we
         and l.driver_id = v_driver_id
    ),
    det as (
      select d.load_id, sum(d.detention_min) det_min
        from public.detention_events_core(v_days_back) d
       group by d.load_id
    ),
    arr as (
      select w.id, w.delivery_time,
             (select min(h.ts) from eld_location_history h
               where h.truck_id = w.truck_id
                 and h.ts between w.delivery_time - interval '18 hours' and w.delivery_time + interval '18 hours'
                 and public.trux_miles(w.delivery_lat, w.delivery_lon, h.lat, h.lng) <= 0.75) eld_arr
        from wk_loads w
       where w.truck_id is not null and w.delivery_lat is not null
    )
    select count(w.id) as loads,
           round(coalesce(sum(w.miles + coalesce(w.empty_miles, 0)), 0), 0) as total_miles,
           round(coalesce(sum(w.miles * d.pay_per_mile
                 + case when d.empty_miles_paid then coalesce(w.empty_miles, 0) * d.pay_per_empty_mile else 0 end), 0), 2) as est_pay,
           (select case when count(*) > 0 then round(
                     count(*) filter (where a.eld_arr <= a.delivery_time + interval '2 hours')::numeric
                     / count(*) * 100, 0) end
              from arr a where a.eld_arr is not null) as on_time_pct,
           round(coalesce(sum(dt.det_min), 0) / 60.0, 1) as detention_hours
      from wk_loads w
      join drivers d on d.id = v_driver_id
      left join det dt on dt.load_id = w.id) t;

  return jsonb_build_object('week_start', ws, 'week_end', we - 1) || coalesce(v_row, '{}'::jsonb);
end;
$function$;
