-- Correction shipped as its OWN migration (006001 was edited after being
-- recorded on prod, so prod kept v1 — the version that counts breadcrumb
-- holes as parked time; live showed a 78.8h 'stretch'). Rule reaffirmed:
-- never edit an applied migration, stamp a new one.
create or replace function public.idle_locations(p_days int default 7)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare v jsonb;
begin
  if not (coalesce(auth.role(), '') = 'service_role'
          or public.my_role() in ('admin','dispatcher','accountant')) then
    raise exception 'Not enough permissions';
  end if;
  with raw as (
    select truck_id, ts, lat, lng, calc_location, speed,
           extract(epoch from (lead(ts) over (partition by truck_id order by ts) - ts)) as gap_s
      from eld_location_history
     where ts > now() - make_interval(days => least(p_days, 14))
       and truck_id is not null and lat is not null
  ), flagged as (
    -- a breadcrumb HOLE (>30 min to the next ping) is unknown time, not
    -- parked time - it ends the stretch like movement does
    select *, case when coalesce(speed, 0) < 1 and coalesce(gap_s, 0) <= 1800
                   then 0 else 1 end as moving
      from raw
  ), pts as (
    select *, sum(moving) over (partition by truck_id order by ts) as grp
      from flagged
  ), stretches as (
    select truck_id, grp,
           min(ts) as started, max(ts) as ended,
           avg(lat) as lat, avg(lng) as lng,
           max(calc_location) as place,
           extract(epoch from (max(ts) - min(ts))) / 3600.0 as hours
      from pts where moving = 0
     group by truck_id, grp
    having extract(epoch from (max(ts) - min(ts))) >= 1800
  ), classified as (
    select s.*,
           exists (
             select 1 from loads l
              where l.delivery_time > now() - make_interval(days => least(p_days, 14) + 3)
                and ((l.pickup_lat is not null and public.trux_miles(s.lat, s.lng, l.pickup_lat, l.pickup_lon) <= 0.75)
                  or (l.delivery_lat is not null and public.trux_miles(s.lat, s.lng, l.delivery_lat, l.delivery_lon) <= 0.75))
           ) as at_dock
      from stretches s
  )
  select jsonb_build_object(
    'days', least(p_days, 14),
    'dock_hours', round(coalesce(sum(hours) filter (where at_dock), 0), 1),
    'elsewhere_hours', round(coalesce(sum(hours) filter (where not at_dock), 0), 1),
    'stretches', count(*),
    'top_elsewhere', coalesce((select jsonb_agg(jsonb_build_object(
        'place', x.place, 'hours', round(x.h, 1), 'stops', x.n) order by x.h desc)
      from (select coalesce(nullif(c2.place, ''), round(c2.lat::numeric, 2)||','||round(c2.lng::numeric, 2)) as place,
                   sum(c2.hours) h, count(*) n
              from classified c2 where not c2.at_dock
             group by 1 order by sum(c2.hours) desc limit 10) x), '[]'::jsonb),
    'note', 'stationary >=30 min; dock = within 0.75 mi of a recent load stop; overnight rest shows under elsewhere - that is expected, look for the outliers',
    'as_of', now()) into v
  from classified;
  return v;
end;
$$;
revoke all on function public.idle_locations(int) from public, anon;
grant execute on function public.idle_locations(int) to authenticated, service_role;
