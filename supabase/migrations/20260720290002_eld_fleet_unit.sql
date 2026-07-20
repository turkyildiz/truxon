-- Show the fleet's OWN unit number on the live map, not the ELD's raw value
-- (the ELD pads unit 03 to "003"). When a vehicle is linked to a truck, use that
-- truck's unit_number; fall back to the ELD number only when unmatched.
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
