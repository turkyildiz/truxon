-- TPIMS real-time truck parking — live spot counts from the state DOT open
-- feeds (KY + IL spec-format, IN GeoJSON; MN/OH feeds are dead; IA/KS/MI/WI
-- need an email registration — owner-owed). Synced every 10 min by the
-- tpims-sync edge function; tablets read OUR table only.
create table public.truck_parking (
  site_id text primary key,
  state text not null,
  name text not null default '',
  lat double precision not null,
  lon double precision not null,
  capacity int,
  available text not null default '',   -- number, 'Low', or 'Unknown'
  trend text not null default '',
  open boolean,
  trust boolean,
  updated_at timestamptz not null default now()
);
create index truck_parking_lat_lon_idx on public.truck_parking (lat, lon);
alter table public.truck_parking enable row level security;
create policy truck_parking_select on public.truck_parking
  for select to authenticated using (true);

create function public.upsert_truck_parking(p_rows jsonb)
returns int
language plpgsql security definer set search_path = public
as $$
declare v_n int;
begin
  if auth.uid() is not null then
    raise exception 'Not enough permissions';
  end if;
  insert into truck_parking (site_id, state, name, lat, lon, capacity, available, trend, open, trust, updated_at)
  select r->>'site_id', r->>'state', left(coalesce(r->>'name', ''), 120),
         (r->>'lat')::double precision, (r->>'lon')::double precision,
         nullif(r->>'capacity', '')::int,
         coalesce(r->>'available', ''), coalesce(r->>'trend', ''),
         (r->>'open')::boolean, (r->>'trust')::boolean, now()
    from jsonb_array_elements(p_rows) r
   where r->>'lat' is not null and r->>'site_id' is not null
  on conflict (site_id) do update
     set available = excluded.available, trend = excluded.trend,
         open = excluded.open, trust = excluded.trust,
         capacity = coalesce(excluded.capacity, truck_parking.capacity),
         name = case when excluded.name <> '' then excluded.name else truck_parking.name end,
         updated_at = now();
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;
revoke all on function public.upsert_truck_parking(jsonb) from public, anon, authenticated;
grant execute on function public.upsert_truck_parking(jsonb) to service_role;

create function public.parking_in_bbox(
  p_min_lat double precision, p_min_lon double precision,
  p_max_lat double precision, p_max_lon double precision
)
returns table (site_id text, state text, name text, lat double precision,
               lon double precision, capacity int, available text, trend text,
               open boolean, updated_at timestamptz)
language sql stable security definer set search_path = public
as $$
  select t.site_id, t.state, t.name, t.lat, t.lon, t.capacity, t.available,
         t.trend, t.open, t.updated_at
    from truck_parking t
   where t.lat between p_min_lat and p_max_lat
     and t.lon between p_min_lon and p_max_lon
   limit 200;
$$;
revoke all on function public.parking_in_bbox(double precision, double precision, double precision, double precision) from public, anon;
grant execute on function public.parking_in_bbox(double precision, double precision, double precision, double precision) to authenticated, service_role;

do $$ begin perform cron.unschedule('truxon-tpims-sync'); exception when others then null; end $$;
select cron.schedule('truxon-tpims-sync', '*/10 * * * *',
  $job$select app_private.cron_edge_call('tpims-sync', '{}'::jsonb)$job$);
