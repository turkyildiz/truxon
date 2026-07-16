-- Multi-stop loads (owner request 2026-07-16): a load carries an ordered
-- list of pickup and delivery stops. loads.pickup_*/delivery_* stay as the
-- denormalized primaries (first pickup / final delivery) for lists, search,
-- and invoices; the full itinerary lives here.

create table public.load_stops (
  id bigint generated always as identity primary key,
  load_id bigint not null references public.loads (id) on delete cascade,
  stop_type text not null check (stop_type in ('pickup', 'delivery')),
  seq int not null default 1,
  facility text not null default '',
  address text not null default '',
  stop_time timestamptz,
  reference text not null default '',  -- PU# / delivery-confirmation # / PO for this stop
  notes text not null default ''
);

create index load_stops_load_idx on public.load_stops (load_id, stop_type, seq);

alter table public.load_stops enable row level security;

-- Same visibility/write surface as the parent loads table.
create policy load_stops_select on public.load_stops
  for select to authenticated
  using (public.my_role() in ('admin', 'dispatcher', 'accountant'));

create policy load_stops_write on public.load_stops
  for all to authenticated
  using (public.my_role() in ('admin', 'dispatcher', 'accountant'))
  with check (public.my_role() in ('admin', 'dispatcher', 'accountant'));

-- Billed loads are locked — their stops must be too (void the invoice first).
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
  return coalesce(new, old);
end;
$$;

create trigger load_stops_guard
  before insert or update or delete on public.load_stops
  for each row execute function public.load_stops_guard();
