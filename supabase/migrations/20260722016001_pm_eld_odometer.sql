-- R8 Block 12 — PM engine on the real odometer. current_odometer() only knew
-- fuel-card readings (driver-typed at the pump): live audit found 9 of 11
-- trucks had NO reading at all (PM-by-miles silently blind for them) and unit
-- 14's prompted value disagreed with the ECU by ~65K miles. The ELD publishes
-- an ECU odometer every sync; prefer whichever source is FRESHER (recency
-- also resolves the unit-14 conflict toward the ECU).
create or replace function public.current_odometer(p_truck_id bigint)
returns bigint
language sql stable security definer set search_path = public as $$
  select reading from (
    select coalesce(nullif(f.telematics_odometer,0), nullif(f.prompted_odometer,0)) as reading,
           f.transaction_time as read_at
      from public.fuel_transactions f
     where f.truck_id = p_truck_id
       and coalesce(nullif(f.telematics_odometer,0), nullif(f.prompted_odometer,0)) is not null
    union all
    select round(vs.odometer)::bigint, vs.ts
      from public.eld_vehicles ev
      join public.eld_vehicle_status vs on vs.vehicle_id = ev.vehicle_id
     where ev.truck_id = p_truck_id and ev.active
       and vs.odometer is not null and vs.odometer > 0
  ) x
  where (public.my_role() in ('admin','accountant','dispatcher','maintenance') or auth.role() = 'service_role')
  order by read_at desc nulls last
  limit 1;
$$;

create or replace function public.fleet_odometers()
returns table (truck_id bigint, unit_number text, odometer bigint, reading_date timestamptz)
language sql stable security definer set search_path = public as $$
  select t.id, t.unit_number, r.reading, r.read_at
    from public.trucks t
    left join lateral (
      select reading, read_at from (
        select coalesce(nullif(f.telematics_odometer,0), nullif(f.prompted_odometer,0)) as reading,
               f.transaction_time as read_at
          from public.fuel_transactions f
         where f.truck_id = t.id
           and coalesce(nullif(f.telematics_odometer,0), nullif(f.prompted_odometer,0)) is not null
        union all
        select round(vs.odometer)::bigint, vs.ts
          from public.eld_vehicles ev
          join public.eld_vehicle_status vs on vs.vehicle_id = ev.vehicle_id
         where ev.truck_id = t.id and ev.active
           and vs.odometer is not null and vs.odometer > 0
      ) c order by c.read_at desc nulls last limit 1
    ) r on true
   where public.my_role() in ('admin','accountant','dispatcher','maintenance')
      or auth.role() = 'service_role';
$$;
