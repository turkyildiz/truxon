-- R4 #8 — deadhead suggester: when a load delivers, which open unassigned
-- pickups are closest to where the truck now sits? Straight-line miles via
-- trux_miles on geocoded stops; booking economics ride along.
create function public.next_load_suggestions(p_load_id bigint)
returns table (
  load_id bigint,
  load_number text,
  customer text,
  pickup_address text,
  pickup_state text,
  deadhead_miles numeric,
  rate numeric,
  miles numeric,
  rpm numeric,
  pickup_time timestamptz
)
language plpgsql security definer set search_path = public stable
as $$
declare
  v_lat numeric; v_lon numeric;
begin
  if auth.uid() is not null and public.my_role() not in ('admin', 'dispatcher', 'accountant') then
    raise exception 'Not enough permissions';
  end if;
  select l.delivery_lat, l.delivery_lon into v_lat, v_lon
    from loads l where l.id = p_load_id;
  if v_lat is null then return; end if;
  return query
  select l.id, l.load_number, c.company_name,
         left(l.pickup_address, 60), l.pickup_state,
         round(public.trux_miles(v_lat, v_lon, l.pickup_lat, l.pickup_lon), 0),
         l.rate, l.miles,
         case when l.miles > 0 then round(l.rate / l.miles, 2) end,
         l.pickup_time
  from loads l
  join customers c on c.id = l.customer_id
  where l.status = 'pending' and l.driver_id is null
    and l.id <> p_load_id
    and l.pickup_lat is not null
  order by public.trux_miles(v_lat, v_lon, l.pickup_lat, l.pickup_lon)
  limit 5;
end;
$$;
revoke all on function public.next_load_suggestions(bigint) from public, anon;
grant execute on function public.next_load_suggestions(bigint) to authenticated, service_role;
