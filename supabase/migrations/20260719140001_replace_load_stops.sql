-- Itinerary edits become atomic. The delete-then-insert lived client-side
-- (frontend data.ts), so a failure between the two calls silently destroyed
-- a load's stops. One RPC = one transaction: either the new itinerary lands
-- or the old one survives.

create or replace function public.replace_load_stops(p_load_id bigint, p_stops jsonb default '[]')
returns setof public.load_stops
language plpgsql security definer set search_path = public
as $$
declare
  l public.loads;
  s jsonb;
  st text;
  pu int := 0;
  del int := 0;
  seq_val int;
begin
  if public.my_role() not in ('admin', 'dispatcher', 'accountant') then
    raise exception 'Not enough permissions';
  end if;
  select * into l from public.loads where id = p_load_id for update;
  if not found then
    raise exception 'Load not found';
  end if;
  if l.status = 'billed' then
    raise exception 'Billed loads are locked; void the invoice first';
  end if;
  if l.status = 'cancelled' then
    raise exception 'Cancelled loads are locked; un-cancel first';
  end if;
  if jsonb_typeof(p_stops) is distinct from 'array' then
    raise exception 'p_stops must be a JSON array';
  end if;

  -- Locks re-checked above once for the whole batch; skip the per-row guard.
  perform set_config('app.load_rpc', '1', true);
  delete from public.load_stops where load_id = p_load_id;
  for s in select * from jsonb_array_elements(p_stops) loop
    st := s ->> 'stop_type';
    if st not in ('pickup', 'delivery') then
      raise exception 'stop_type must be pickup or delivery';
    end if;
    if st = 'pickup' then pu := pu + 1; seq_val := pu; else del := del + 1; seq_val := del; end if;
    insert into public.load_stops (load_id, stop_type, seq, facility, address, stop_time, reference, notes)
    values (
      p_load_id,
      st,
      seq_val,
      coalesce(s ->> 'facility', ''),
      coalesce(s ->> 'address', ''),
      nullif(s ->> 'stop_time', '')::timestamptz,
      coalesce(s ->> 'reference', ''),
      coalesce(s ->> 'notes', '')
    );
  end loop;
  perform set_config('app.load_rpc', '', true);

  return query
    select * from public.load_stops where load_id = p_load_id
     order by stop_type desc, seq;
end;
$$;

revoke execute on function public.replace_load_stops(bigint, jsonb) from public, anon;
grant execute on function public.replace_load_stops(bigint, jsonb) to authenticated;

-- Stops of cancelled loads are locked like billed ones (the loads row
-- already is; its itinerary must not drift underneath it).
create or replace function public.load_stops_guard()
returns trigger language plpgsql security definer set search_path = public
as $$
declare
  l_status public.load_status;
begin
  if current_setting('app.load_rpc', true) = '1' then
    return coalesce(new, old);
  end if;
  select status into l_status from public.loads where id = coalesce(new.load_id, old.load_id);
  if l_status = 'billed' then
    raise exception 'Billed loads are locked; void the invoice first';
  end if;
  if l_status = 'cancelled' then
    raise exception 'Cancelled loads are locked; un-cancel first';
  end if;
  return coalesce(new, old);
end;
$$;
