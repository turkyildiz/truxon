-- R9 #115/#116: load builder auto-suggest — rank active drivers for a pickup
-- by availability, deadhead from their last known position (ELD first, last
-- delivery as fallback), HOS drive hours, and lane history. Each row carries
-- the repositioning bill (deadhead miles x GL all-in $/mi) so a far-away
-- driver is a priced decision, not a surprise (#116). Honest about blindness:
-- drivers with no position report deadhead null, never 0.
create or replace function public.suggest_assignment(
  p_pickup_lat numeric, p_pickup_lon numeric,
  p_pickup_time timestamptz default null,
  p_pickup_state text default null, p_delivery_state text default null)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_rpm numeric := coalesce((public.fleet_cost_basis()->>'gl_all_in_rpm')::numeric, 0);
  v_rows jsonb;
begin
  if not (coalesce(auth.role(), '') = 'service_role'
          or public.my_role() in ('admin','dispatcher')) then
    raise exception 'Not enough permissions';
  end if;
  if p_pickup_lat is null or p_pickup_lon is null then
    raise exception 'pickup coordinates required';
  end if;

  select jsonb_agg(t order by t.busy asc, t.deadhead_miles asc nulls last,
                   t.lane_runs desc, t.hos_drive_h desc nulls last) into v_rows
  from (
    select d.id as driver_id, d.full_name as driver,
           pos.truck_id as suggested_truck_id, pos.unit as suggested_truck,
           pos.source as position_source, pos.place as last_seen,
           case when pos.lat is not null
                then round(public.trux_miles(pos.lat, pos.lon, p_pickup_lat, p_pickup_lon) * 1.2, 0)
           end as deadhead_miles,
           case when pos.lat is not null and v_rpm > 0
                then round(public.trux_miles(pos.lat, pos.lon, p_pickup_lat, p_pickup_lon) * 1.2 * v_rpm, 0)
           end as reposition_cost,
           round(hos.drive_sec / 3600.0, 1) as hos_drive_h,
           busy.load_number as on_load, busy.free_at,
           (busy.load_number is not null) as busy,
           coalesce(hist.n, 0) as lane_runs
      from drivers d
      -- freshest position: the ELD truck this driver was last seen in (24h),
      -- else where their last delivered load dropped (7d)
      left join lateral (
        select * from (
          select vs.lat, vs.lon, ev.truck_id,
                 coalesce(nullif(tk.unit_number,''), ev.number) as unit,
                 vs.calc_location as place, 'eld' as source, vs.ts
            from eld_vehicle_status vs
            join eld_vehicles ev on ev.vehicle_id = vs.vehicle_id
            left join eld_drivers ed on ed.driver_id = vs.eld_driver_id
            left join trucks tk on tk.id = ev.truck_id
           where ed.matched_driver_id = d.id and vs.lat is not null
             and vs.ts > now() - interval '24 hours'
          union all
          select l.delivery_lat, l.delivery_lon, l.truck_id,
                 tk2.unit_number, l.delivery_address, 'last_delivery', l.delivery_time
            from loads l left join trucks tk2 on tk2.id = l.truck_id
           where l.driver_id = d.id and l.status in ('completed','billed')
             and l.delivery_lat is not null
             and l.delivery_time > now() - interval '7 days'
        ) p order by (source = 'eld') desc, ts desc limit 1) pos on true
      left join lateral (
        select st.drive_sec from eld_drivers ed
          join eld_driver_status st on st.driver_id = ed.driver_id
         where ed.matched_driver_id = d.id limit 1) hos on true
      -- already rolling? busy unless they deliver before this pickup
      left join lateral (
        select l.load_number, l.delivery_time as free_at from loads l
         where l.driver_id = d.id and l.status in ('assigned','in_transit')
           and (p_pickup_time is null or l.delivery_time is null
                or l.delivery_time > p_pickup_time)
         order by l.delivery_time desc nulls first limit 1) busy on true
      left join lateral (
        select count(*) as n from loads l
         where l.driver_id = d.id and l.status in ('completed','billed')
           and p_pickup_state is not null and l.pickup_state = p_pickup_state
           and (p_delivery_state is null or l.delivery_state = p_delivery_state)
           and l.delivery_time > now() - interval '365 days') hist on true
     where d.status = 'active') t;

  return jsonb_build_object(
    'suggestions', coalesce(v_rows, '[]'::jsonb),
    'all_in_rpm', v_rpm,
    'note', 'deadhead = straight-line x1.2 from ELD position (24h) or last delivery (7d); null = no position known. Reposition cost = deadhead x GL all-in $/mi.',
    'as_of', now());
end;
$$;
revoke all on function public.suggest_assignment(numeric, numeric, timestamptz, text, text) from public, anon, authenticated;
grant execute on function public.suggest_assignment(numeric, numeric, timestamptz, text, text) to authenticated, service_role;
