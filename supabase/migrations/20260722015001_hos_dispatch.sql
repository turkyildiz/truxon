-- R8 Block 8 — HOS-aware dispatch. The fleet map already shows HOS per truck,
-- but the Dispatch assignment picker was blind: nothing connected ELD drivers
-- to Truxon driver rows (eld_drivers.matched_driver_id: 0 of 26 set, and no
-- code ever set it). Match by normalized full name (exact, both orders) —
-- fills NULLs only, never overwrites a manual link.

create or replace function public.eld_link_drivers()
returns int
language plpgsql security definer set search_path = public
as $$
declare n int;
begin
  update public.eld_drivers ed
     set matched_driver_id = d.id
    from public.drivers d
   where ed.matched_driver_id is null
     and lower(regexp_replace(trim(coalesce(ed.first_name,'')||' '||coalesce(ed.last_name,'')), '\s+', ' ', 'g'))
         in (lower(regexp_replace(trim(d.full_name), '\s+', ' ', 'g')),
             -- "Last First" rosters happen; accept the reversed order too
             lower(regexp_replace(trim((string_to_array(trim(d.full_name),' '))[array_length(string_to_array(trim(d.full_name),' '),1)]
                   ||' '||(string_to_array(trim(d.full_name),' '))[1]), '\s+', ' ', 'g')))
     and nullif(trim(coalesce(ed.first_name,'')||coalesce(ed.last_name,'')),'') is not null;
  get diagnostics n = row_count;
  return n;
end;
$$;
revoke all on function public.eld_link_drivers() from public, anon;
grant execute on function public.eld_link_drivers() to service_role;

-- fleet feed now carries the matched Truxon driver id so the Dispatch picker
-- can say who actually has hours
create or replace function public.eld_fleet_live()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if public.my_role() not in ('admin','dispatcher','accountant') then
    raise exception 'Not enough permissions';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'vehicle_id', ev.vehicle_id,
      'unit', coalesce(nullif(t.unit_number, ''), ev.number),
      'vin', ev.vin,
      'truck_id', ev.truck_id,
      'lat', vs.lat, 'lng', vs.lon,
      'speed', vs.speed, 'odometer', vs.odometer, 'fuel_level', vs.fuel_level,
      'status', vs.status, 'location', vs.calc_location, 'ts', vs.ts,
      'driver_name', nullif(trim(coalesce(ed.first_name,'')||' '||coalesce(ed.last_name,'')),''),
      'driver_id', ed.matched_driver_id,
      'hos_drive_sec', ds.drive_sec, 'hos_shift_sec', ds.shift_sec,
      'hos_cycle_sec', ds.cycle_sec, 'duty_status', ds.current_status
    ) order by coalesce(nullif(t.unit_number, ''), ev.number))
    from public.eld_vehicle_status vs
    join public.eld_vehicles ev on ev.vehicle_id = vs.vehicle_id
    left join public.trucks t on t.id = ev.truck_id
    left join public.eld_drivers ed on ed.driver_id = vs.eld_driver_id
    left join public.eld_driver_status ds on ds.driver_id = vs.eld_driver_id
    where ev.active
  ), '[]'::jsonb);
end;
$$;
revoke all on function public.eld_fleet_live() from public, anon;
grant execute on function public.eld_fleet_live() to authenticated;

select public.eld_link_drivers();
