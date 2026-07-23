-- R9 #52/#53: ETA + late-risk for rolling loads, while it's still fixable.
-- Estimate is stated honestly: straight-line miles x 1.25 road factor at
-- 47 mph net progress, against the delivery appointment. HOS is checked too:
-- a driver without enough drive hours left forces the risk up even when the
-- clock math looks fine.
create or replace function public.load_eta_risk()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare v_rows jsonb;
begin
  if not (coalesce(auth.role(), '') = 'service_role'
          or public.my_role() in ('admin','dispatcher','accountant')) then
    raise exception 'Not enough permissions';
  end if;
  select jsonb_agg(t order by t.slack_h nulls last) into v_rows from (
    select l.id as load_id, l.load_number,
           c.company_name as customer,
           d.full_name as driver,
           tk.unit_number as unit,
           l.delivery_time as appointment,
           round(pos.mi_to_go, 0) as miles_to_go,
           now() + make_interval(hours => (pos.mi_to_go / 47.0)::numeric::int,
                                 mins => (mod((pos.mi_to_go / 47.0)::numeric * 60, 60))::int) as eta,
           round(extract(epoch from (l.delivery_time - now())) / 3600.0
                 - pos.mi_to_go / 47.0, 1) as slack_h,
           round(coalesce(ds.drive_sec, 0) / 3600.0, 1) as hos_drive_h,
           case
             when pos.mi_to_go / 47.0 > extract(epoch from (l.delivery_time - now())) / 3600.0
               then 'late'
             when coalesce(ds.drive_sec, 999999) / 3600.0 < pos.mi_to_go / 47.0
               then 'hos_short'
             when pos.mi_to_go / 47.0 > extract(epoch from (l.delivery_time - now())) / 3600.0 - 1
               then 'tight'
             else 'ok'
           end as risk
      from loads l
      join customers c on c.id = l.customer_id
      left join drivers d on d.id = l.driver_id
      left join trucks tk on tk.id = l.truck_id
      join lateral (
        select public.trux_miles(vs.lat, vs.lon, l.delivery_lat, l.delivery_lon) * 1.25 as mi_to_go
          from eld_vehicles ev
          join eld_vehicle_status vs on vs.vehicle_id = ev.vehicle_id
         where ev.truck_id = l.truck_id and vs.lat is not null
           and vs.ts > now() - interval '3 hours'
         limit 1) pos on pos.mi_to_go is not null
      left join lateral (
        select st.drive_sec from eld_drivers ed
          join eld_driver_status st on st.driver_id = ed.driver_id
         where ed.matched_driver_id = l.driver_id limit 1) ds on true
     where l.status = 'in_transit'
       and l.delivery_time is not null and l.delivery_lat is not null
       and l.delivery_time > now() - interval '2 hours'
       and l.delivery_time < now() + interval '48 hours') t;
  return jsonb_build_object(
    'note', 'straight-line x1.25 at 47 mph net - an estimate, not a promise',
    'loads', coalesce(v_rows, '[]'::jsonb),
    'as_of', now());
end;
$$;
revoke all on function public.load_eta_risk() from public, anon;
grant execute on function public.load_eta_risk() to authenticated, service_role;
