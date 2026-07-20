-- Geocode writes must go through here. A direct UPDATE of a billed load is
-- rejected by loads_before_update ("Billed loads are locked") unless the
-- app.load_rpc guard flag is set — and most historical loads are billed, so the
-- geocode backfill's direct writes were silently failing on them. This RPC sets
-- the flag and writes ONLY the geocode metadata (never status/invoice/money), so
-- stamping a stop's coordinates on a locked load is safe and allowed.
create or replace function public.apply_load_geocode(
  p_load_id bigint,
  p_pickup_lat numeric, p_pickup_lon numeric, p_pickup_state text,
  p_delivery_lat numeric, p_delivery_lon numeric, p_delivery_state text)
returns void
language plpgsql security definer set search_path = public as $$
begin
  perform set_config('app.load_rpc', '1', true);   -- metadata-only write; bypass the billed-lock guard
  update public.loads set
    pickup_lat     = p_pickup_lat,
    pickup_lon     = p_pickup_lon,
    pickup_state   = nullif(p_pickup_state, ''),
    delivery_lat   = p_delivery_lat,
    delivery_lon   = p_delivery_lon,
    delivery_state = nullif(p_delivery_state, ''),
    geocoded_at    = now()
  where id = p_load_id;
  perform set_config('app.load_rpc', '', true);
end;
$$;
revoke all on function public.apply_load_geocode(bigint, numeric, numeric, text, numeric, numeric, text) from public, anon, authenticated;
-- Called by the geocode edge function with the service role only.
