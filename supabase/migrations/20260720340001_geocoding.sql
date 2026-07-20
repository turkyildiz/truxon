-- Geocoding foundation (unblocks per-lane rate history now, detention later).
-- Loads carry only freeform pickup/delivery address text; this resolves each
-- stop to lat/lon + state via Google, so lanes can be grouped by real geography
-- instead of fragile string parsing. Two pieces:
--   geocode_cache   — one row per normalized address string, so a repeated
--                     shipper/receiver is never re-geocoded (Google is billable)
--   loads.*_lat/lon/state + geocoded_at — denormalized onto the load for fast
--                     lane grouping and (later) ELD-breadcrumb detention joins
-- The geocode edge function fills both with the service role.

-- Reusable address → coordinates cache.
create table if not exists public.geocode_cache (
  norm_address  text primary key,          -- lowercased, whitespace-collapsed key
  formatted     text not null default '',   -- Google's formatted_address
  lat           numeric,
  lon           numeric,
  city          text not null default '',
  state         text not null default '',   -- 2-letter (administrative_area_level_1)
  postal        text not null default '',
  country       text not null default '',
  location_type text not null default '',   -- ROOFTOP / RANGE_INTERPOLATED / APPROXIMATE
  partial       boolean not null default false,
  source        text not null default 'google',
  geocoded_at   timestamptz not null default now()
);
alter table public.geocode_cache enable row level security;
-- No policies: only the service role (geocode edge fn) reads/writes it.

-- Denormalized stop geography on each load.
alter table public.loads
  add column if not exists pickup_lat     numeric,
  add column if not exists pickup_lon     numeric,
  add column if not exists pickup_state   text,
  add column if not exists delivery_lat   numeric,
  add column if not exists delivery_lon   numeric,
  add column if not exists delivery_state text,
  add column if not exists geocoded_at    timestamptz;

create index if not exists loads_lane_idx on public.loads (pickup_state, delivery_state)
  where pickup_state is not null and delivery_state is not null;

-- Lane rate history: what a given origin→destination state lane has actually paid
-- us per mile. Sharpens the load-margin panel with real lane economics (the rate
-- signal a broker negotiation actually turns on). Trailing 180 days of
-- completed/billed loads with real miles + rate on that lane.
-- Admin/dispatcher/accountant (matches the dispatch surface).
create or replace function public.lane_rate_history(p_origin_state text, p_dest_state text)
returns jsonb
language plpgsql security definer set search_path = public stable as $$
declare v jsonb;
begin
  if public.my_role() not in ('admin', 'dispatcher', 'accountant') then
    raise exception 'Not enough permissions';
  end if;
  if coalesce(p_origin_state, '') = '' or coalesce(p_dest_state, '') = '' then
    return jsonb_build_object('load_count', 0);
  end if;

  select jsonb_build_object(
           'origin', upper(p_origin_state), 'dest', upper(p_dest_state),
           'load_count', count(*),
           'avg_rpm',    round(avg(l.rate / l.miles), 2),
           'median_rpm', round((percentile_cont(0.5) within group (order by l.rate / l.miles))::numeric, 2),
           'avg_rate',   round(avg(l.rate), 0),
           'avg_miles',  round(avg(l.miles), 0))
    into v
    from public.loads l
   where upper(l.pickup_state) = upper(p_origin_state)
     and upper(l.delivery_state) = upper(p_dest_state)
     and l.status in ('completed', 'billed')
     and l.miles > 0 and l.rate > 0
     and l.delivery_time > now() - interval '180 days';

  return coalesce(v, jsonb_build_object('load_count', 0));
end;
$$;
revoke all on function public.lane_rate_history(text, text) from public, anon;
grant execute on function public.lane_rate_history(text, text) to authenticated;
