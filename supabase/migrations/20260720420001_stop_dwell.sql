-- Northstar: average driver dwell at shipper/consignee (playbook #229/#230).
-- Generalizes the detention breadcrumb math to ALL stops (not just the ones over
-- free time): the span of the assigned truck's ELD breadcrumbs near the stop,
-- around its appointment. Averages pickup vs delivery dwell over the window.
-- Admin/dispatcher/accountant + service_role (for Trux).
create or replace function public.stop_dwell_summary(p_days int default 45, p_radius_mi numeric default 0.75)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare pu_avg numeric; de_avg numeric; pu_n int; de_n int;
begin
  if auth.role() <> 'service_role' and public.my_role() not in ('admin','dispatcher','accountant') then
    raise exception 'Not enough permissions';
  end if;
  with stops as (
    select l.id as load_id, 'pickup'::text as stop_type, l.pickup_time as appt,
           l.pickup_lat as lat, l.pickup_lon as lon, l.truck_id
      from public.loads l
     where l.truck_id is not null and l.pickup_lat is not null and l.pickup_time is not null
       and l.delivery_time > now() - make_interval(days => p_days)
    union all
    select l.id, 'delivery', l.delivery_time, l.delivery_lat, l.delivery_lon, l.truck_id
      from public.loads l
     where l.truck_id is not null and l.delivery_lat is not null and l.delivery_time is not null
       and l.delivery_time > now() - make_interval(days => p_days)
  ),
  dwell as (
    select s.stop_type,
           (select min(h.ts) from public.eld_location_history h
             where h.truck_id = s.truck_id
               and h.ts between s.appt - interval '18 hours' and s.appt + interval '18 hours'
               and public.trux_miles(s.lat, s.lon, h.lat, h.lng) <= p_radius_mi) as arr,
           (select max(h.ts) from public.eld_location_history h
             where h.truck_id = s.truck_id
               and h.ts between s.appt - interval '18 hours' and s.appt + interval '18 hours'
               and public.trux_miles(s.lat, s.lon, h.lat, h.lng) <= p_radius_mi) as dep
      from stops s
  ),
  m as (
    select stop_type, extract(epoch from (dep - arr)) / 3600.0 as hrs
      from dwell where arr is not null and dep is not null and dep > arr
  )
  select round(avg(hrs) filter (where stop_type='pickup'), 1),
         round(avg(hrs) filter (where stop_type='delivery'), 1),
         count(*) filter (where stop_type='pickup'),
         count(*) filter (where stop_type='delivery')
    into pu_avg, de_avg, pu_n, de_n from m;

  return jsonb_build_object(
    'avg_dwell_hours_shipper', pu_avg, 'stops_measured_shipper', coalesce(pu_n,0),
    'avg_dwell_hours_consignee', de_avg, 'stops_measured_consignee', coalesce(de_n,0));
end;
$$;
revoke all on function public.stop_dwell_summary(int, numeric) from public, anon;
grant execute on function public.stop_dwell_summary(int, numeric) to authenticated;

update public.playbook_metrics set status='live', source='stop_dwell_summary.avg_dwell_hours_shipper', updated_at=now() where number=229 and status<>'live';
update public.playbook_metrics set status='live', source='stop_dwell_summary.avg_dwell_hours_consignee', updated_at=now() where number=230 and status<>'live';
