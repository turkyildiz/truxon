-- R8: route replay — the GPS breadcrumb trail a load actually drove, for the
-- load detail page. Window = pickup appointment (or first stop_time) minus 2h
-- through delivery + 4h, clamped to now. Downsampled server-side to <= ~500
-- points so a 3-day load doesn't ship 40k rows to the browser.
create or replace function public.load_route(p_load_id bigint)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_truck bigint;
  v_from timestamptz;
  v_to timestamptz;
  n bigint;
  step int;
  out jsonb;
begin
  if auth.role() <> 'service_role' and coalesce(public.my_role()::text,'none') not in ('admin','accountant','dispatcher') then
    raise exception 'Not enough permissions';
  end if;

  select l.truck_id,
         coalesce(l.pickup_time, (select min(s.stop_time) from load_stops s where s.load_id = l.id)) - interval '2 hours',
         least(coalesce(l.delivery_time, now()) + interval '4 hours', now())
    into v_truck, v_from, v_to
    from loads l where l.id = p_load_id;
  if v_truck is null or v_from is null then
    return jsonb_build_object('points', '[]'::jsonb, 'reason', 'no truck or window');
  end if;

  select count(*) into n from eld_location_history h
   where h.truck_id = v_truck and h.ts between v_from and v_to;
  if n = 0 then
    return jsonb_build_object('points', '[]'::jsonb, 'reason', 'no breadcrumbs in window');
  end if;
  step := greatest(1, (n / 500)::int);

  select jsonb_build_object(
    'points', coalesce(jsonb_agg(jsonb_build_array(round(q.lat, 5), round(q.lng, 5)) order by q.ts), '[]'::jsonb),
    'from', min(q.ts), 'to', max(q.ts), 'total_pings', n, 'sampled_every', step)
    into out
  from (
    select h.lat, h.lng, h.ts,
           row_number() over (order by h.ts) as rn
      from eld_location_history h
     where h.truck_id = v_truck and h.ts between v_from and v_to
       and h.lat is not null and h.lng is not null
  ) q
  where q.rn % step = 0;
  return out;
end;
$$;
revoke execute on function public.load_route(bigint) from public, anon;
grant execute on function public.load_route(bigint) to authenticated, service_role;
