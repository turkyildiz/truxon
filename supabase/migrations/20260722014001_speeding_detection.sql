-- R8 Block 7 — speeding detection from ELD breadcrumbs (GPS speed is mph:
-- live p99 = 77, max 91, median-moving 67 → fleet governor sits ~70).
-- Same time-weighting idea as idle_summary: each breadcrumb owns the seconds
-- until the next fix (gaps over 15 min = engine off / signal lost, dropped).
--
--  • speeding_summary(p_days): per-truck minutes over 70/75/80 + max speed +
--    worst moment (ts + place), normalized per-1000-ELD-miles event rate
--  • sentinel: speeding_hot warn ≥30 min over 75 in 14d, critical ≥15 min
--    over 80 (spliced separately in the sentinel migration below)
--  • playbook #262 "Speed Over Threshold Event Rate" flips live

create or replace function public.speeding_summary(p_days int default 14)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare v jsonb;
begin
  if auth.uid() is not null and public.my_role() not in ('admin', 'dispatcher', 'accountant') then
    raise exception 'Not enough permissions';
  end if;

  with pts as (
    select truck_id, ts, speed, calc_location,
           extract(epoch from (lead(ts) over (partition by truck_id order by ts) - ts)) as gap_s
      from eld_location_history
     where truck_id is not null and speed is not null
       and ts > now() - make_interval(days => p_days)
  ), w as (
    select truck_id, ts, speed, calc_location,
           least(gap_s, 900) as sec           -- 15-min cap, same as idle_summary
      from pts
     where gap_s is not null and gap_s between 1 and 900
  ), per as (
    select truck_id,
           round(sum(sec) filter (where speed >= 70) / 60.0, 1) as min_over_70,
           round(sum(sec) filter (where speed >= 75) / 60.0, 1) as min_over_75,
           round(sum(sec) filter (where speed >= 80) / 60.0, 1) as min_over_80,
           max(speed) as max_speed
      from w group by truck_id
  ), worst as (
    select distinct on (truck_id) truck_id, ts, speed, calc_location
      from w where speed >= 75
     order by truck_id, speed desc, ts desc
  ), mi as (
    select truck_id, sum(miles) as mi from eld_daily_miles
     where day >= current_date - p_days group by truck_id
  )
  select jsonb_build_object(
    'window_days', p_days,
    'thresholds_mph', jsonb_build_array(70, 75, 80),
    'fleet', (select jsonb_build_object(
        'minutes_over_75', coalesce(sum(p.min_over_75), 0),
        'minutes_over_80', coalesce(sum(p.min_over_80), 0),
        'max_speed', max(p.max_speed),
        -- the playbook rate: minutes at 75+ per 1,000 actual miles
        'events_per_1000mi', case when coalesce((select sum(mi) from mi), 0) > 0
          then round(coalesce(sum(p.min_over_75), 0) / (select sum(mi) from mi) * 1000, 2) end)
       from per p),
    'trucks', (select coalesce(jsonb_agg(jsonb_build_object(
        'truck_id', p.truck_id,
        'unit', t.unit_number,
        'min_over_70', coalesce(p.min_over_70, 0),
        'min_over_75', coalesce(p.min_over_75, 0),
        'min_over_80', coalesce(p.min_over_80, 0),
        'max_speed', p.max_speed,
        'worst_at', wo.ts, 'worst_speed', wo.speed, 'worst_place', wo.calc_location)
        order by p.min_over_75 desc nulls last), '[]'::jsonb)
       from per p
       join trucks t on t.id = p.truck_id
       left join worst wo on wo.truck_id = p.truck_id)
  ) into v;
  return v;
end;
$$;
revoke all on function public.speeding_summary(int) from public, anon;
grant execute on function public.speeding_summary(int) to authenticated, service_role;

update public.playbook_metrics
   set status = 'live',
       source = 'speeding_summary() — ELD GPS time-weighted minutes at 75+ mph per 1,000 actual miles; per-truck detail incl. worst moment',
       updated_at = now()
 where number = 262;
