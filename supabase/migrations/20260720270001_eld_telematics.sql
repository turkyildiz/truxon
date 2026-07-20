-- ELD telematics ingestion (Northstar). Devours the DriveHOS partner feed:
-- vehicles, drivers, live vehicle status (odometer/GPS/fuel), live driver HOS
-- clocks, and the full GPS breadcrumb history. This is the telematics backbone
-- the predictive layer rides on (accurate miles, live map, detention, HOS-aware
-- dispatch, breakdown signals).
--
-- The eld-sync edge function writes these with the service role (bypasses RLS);
-- app users get read-only access, admin/dispatcher/accountant.

-- ── rosters ──────────────────────────────────────────────────────────────────
create table if not exists public.eld_vehicles (
  vehicle_id uuid primary key,              -- ELD's id
  number text not null default '',          -- unit number (matches trucks)
  vin text not null default '',
  active boolean not null default true,
  truck_id bigint references public.trucks (id) on delete set null,  -- matched
  last_seen timestamptz not null default now(),
  raw jsonb
);
create index if not exists eld_vehicles_truck_idx on public.eld_vehicles (truck_id);

create table if not exists public.eld_drivers (
  driver_id uuid primary key,               -- ELD's id
  username text not null default '',
  first_name text not null default '',
  last_name text not null default '',
  active boolean not null default true,
  matched_driver_id bigint references public.drivers (id) on delete set null,
  last_seen timestamptz not null default now(),
  raw jsonb
);

-- ── live status (one row per vehicle / driver, upserted each sync) ────────────
create table if not exists public.eld_vehicle_status (
  vehicle_id uuid primary key references public.eld_vehicles (vehicle_id) on delete cascade,
  eld_driver_id uuid,
  number text, vin text,
  odometer numeric, fuel_level numeric, speed numeric,
  lat numeric, lon numeric,
  status text,                              -- IN_MOTION / OFFLINE / ...
  ts timestamptz,                           -- device timestamp
  calc_location text,                       -- human-readable place
  updated_at timestamptz not null default now()
);

create table if not exists public.eld_driver_status (
  driver_id uuid primary key references public.eld_drivers (driver_id) on delete cascade,
  username text,
  break_sec int, drive_sec int, shift_sec int, cycle_sec int,   -- HOS clocks (seconds remaining)
  current_status text,                      -- DS_D driving, etc.
  updated_at timestamptz not null default now()
);

-- ── GPS breadcrumb history ───────────────────────────────────────────────────
create table if not exists public.eld_location_history (
  id uuid primary key,                      -- ELD's breadcrumb id (dedup)
  vehicle_id uuid references public.eld_vehicles (vehicle_id) on delete cascade,
  truck_id bigint references public.trucks (id) on delete set null,
  vehicle_number text, vin text,
  lat numeric, lng numeric, speed numeric, direction numeric,
  status text, calc_location text,
  ts timestamptz not null
);
create index if not exists eld_loc_vehicle_ts_idx on public.eld_location_history (vehicle_id, ts desc);
create index if not exists eld_loc_truck_ts_idx on public.eld_location_history (truck_id, ts desc);

-- ── RLS: staff read; only the service-role sync writes ───────────────────────
do $$
declare tbl text;
begin
  foreach tbl in array array['eld_vehicles','eld_drivers','eld_vehicle_status','eld_driver_status','eld_location_history'] loop
    execute format('alter table public.%I enable row level security', tbl);
    execute format('drop policy if exists %I on public.%I', tbl||'_read', tbl);
    execute format($p$create policy %I on public.%I for select to authenticated
        using (public.my_role() in ('admin','dispatcher','accountant'))$p$, tbl||'_read', tbl);
  end loop;
end $$;

-- ── truck matching: link ELD vehicles to trucks by VIN, then by unit number ──
create or replace function public.eld_link_vehicles()
returns int
language plpgsql security definer set search_path = public
as $$
declare n int;
begin
  update public.eld_vehicles ev set truck_id = t.id
    from public.trucks t
   where ev.truck_id is null
     and nullif(ev.vin,'') is not null
     and upper(ev.vin) = upper(t.vin);
  -- fallback: digit-normalized unit number (ELD '003' → truck '3')
  update public.eld_vehicles ev set truck_id = t.id
    from public.trucks t
   where ev.truck_id is null
     and regexp_replace(ev.number,'\D','','g') <> ''
     and ltrim(regexp_replace(ev.number,'\D','','g'),'0') = ltrim(regexp_replace(t.unit_number,'\D','','g'),'0');
  -- propagate the match onto history rows that arrived before linking
  update public.eld_location_history h set truck_id = ev.truck_id
    from public.eld_vehicles ev
   where h.vehicle_id = ev.vehicle_id and h.truck_id is null and ev.truck_id is not null;
  get diagnostics n = row_count;
  return n;
end;
$$;
revoke all on function public.eld_link_vehicles() from public, anon;

-- ── live fleet feed for the map: latest ELD status per truck + driver + HOS ──
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
      'unit', ev.number,
      'vin', ev.vin,
      'truck_id', ev.truck_id,
      'lat', vs.lat, 'lng', vs.lon,
      'speed', vs.speed, 'odometer', vs.odometer, 'fuel_level', vs.fuel_level,
      'status', vs.status, 'location', vs.calc_location, 'ts', vs.ts,
      'driver_name', nullif(trim(coalesce(ed.first_name,'')||' '||coalesce(ed.last_name,'')),''),
      'hos_drive_sec', ds.drive_sec, 'hos_shift_sec', ds.shift_sec,
      'hos_cycle_sec', ds.cycle_sec, 'duty_status', ds.current_status
    ) order by ev.number)
    from public.eld_vehicle_status vs
    join public.eld_vehicles ev on ev.vehicle_id = vs.vehicle_id
    left join public.eld_drivers ed on ed.driver_id = vs.eld_driver_id
    left join public.eld_driver_status ds on ds.driver_id = vs.eld_driver_id
    where ev.active
  ), '[]'::jsonb);
end;
$$;
revoke all on function public.eld_fleet_live() from public, anon;
grant execute on function public.eld_fleet_live() to authenticated;
