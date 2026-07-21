-- TABLET DAY #5 — trucker POIs for the in-app map: truck stops, rest areas,
-- weigh stations from OpenStreetMap, bulk-cached here so tablets never hit
-- Overpass directly (one respectful pull, monthly refresh). TPIMS real-time
-- parking availability layers on later.
create table public.map_pois (
  osm_id bigint not null,
  kind text not null check (kind in ('truck_stop', 'rest_area', 'weigh_station')),
  name text not null default '',
  lat double precision not null,
  lon double precision not null,
  updated_at timestamptz not null default now(),
  primary key (osm_id, kind)
);
create index map_pois_lat_lon_idx on public.map_pois (lat, lon);
alter table public.map_pois enable row level security;
create policy map_pois_select on public.map_pois
  for select to authenticated using (true);  -- public geodata, any login

-- Service-only bulk upsert used by the poi-sync edge function.
create function public.upsert_map_pois(p_kind text, p_rows jsonb)
returns int
language plpgsql security definer set search_path = public
as $$
declare v_n int;
begin
  if auth.uid() is not null then
    raise exception 'Not enough permissions';  -- service path only
  end if;
  insert into map_pois (osm_id, kind, name, lat, lon, updated_at)
  select (r->>'id')::bigint, p_kind,
         left(coalesce(r->>'name', ''), 120),
         (r->>'lat')::double precision, (r->>'lon')::double precision, now()
    from jsonb_array_elements(p_rows) r
   where r->>'lat' is not null and r->>'lon' is not null
  on conflict (osm_id, kind) do update
     set name = excluded.name, lat = excluded.lat, lon = excluded.lon,
         updated_at = now();
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;
revoke all on function public.upsert_map_pois(text, jsonb) from public, anon, authenticated;
grant execute on function public.upsert_map_pois(text, jsonb) to service_role;

-- What the map asks for: POIs inside the visible box, capped.
create function public.pois_in_bbox(
  p_min_lat double precision, p_min_lon double precision,
  p_max_lat double precision, p_max_lon double precision,
  p_kinds text[] default array['truck_stop', 'rest_area', 'weigh_station']
)
returns table (kind text, name text, lat double precision, lon double precision)
language sql stable security definer set search_path = public
as $$
  select m.kind, m.name, m.lat, m.lon
    from map_pois m
   where m.lat between p_min_lat and p_max_lat
     and m.lon between p_min_lon and p_max_lon
     and m.kind = any (p_kinds)
   limit 500;
$$;
revoke all on function public.pois_in_bbox(double precision, double precision, double precision, double precision, text[]) from public, anon;
grant execute on function public.pois_in_bbox(double precision, double precision, double precision, double precision, text[]) to authenticated, service_role;

-- Monthly refresh, first Sunday 04:15 UTC.
do $$ begin perform cron.unschedule('truxon-poi-sync'); exception when others then null; end $$;
select cron.schedule('truxon-poi-sync', '15 4 1-7 * 0',
  $job$select app_private.cron_edge_call('poi-sync', '{}'::jsonb)$job$);
