-- Companion Phase 1: driver profile link, driver DTOs/status/duty,
-- GPS ingest, push_devices. Plus remaining integrity: void paid, double-book.

-- ========== Integrity: void paid invoices ==========

create or replace function public.void_invoice(p_invoice_id bigint)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  inv public.invoices;
  voided_ids bigint[];
begin
  if public.my_role() not in ('admin', 'accountant', 'dispatcher') then
    raise exception 'Not enough permissions';
  end if;
  select * into inv from public.invoices where id = p_invoice_id for update;
  if not found then
    raise exception 'Invoice not found';
  end if;
  if inv.status = 'paid' then
    raise exception 'Cannot void a paid invoice';
  end if;

  select coalesce(array_agg(id), '{}') into voided_ids from public.loads where invoice_id = p_invoice_id;

  perform set_config('app.load_rpc', '1', true);
  update public.loads set invoice_id = null, status = 'completed' where id = any(voided_ids);
  perform set_config('app.load_rpc', '', true);

  insert into public.activity_log (entity_type, entity_id, user_id, action, detail)
  select 'load', id, auth.uid(), 'status_changed', 'billed → completed (invoice ' || inv.invoice_number || ' voided)'
    from unnest(voided_ids) as id;

  delete from public.invoices where id = p_invoice_id;
end;
$$;

revoke execute on function public.void_invoice(bigint) from public, anon;
grant execute on function public.void_invoice(bigint) to authenticated;

-- ========== Double-booking guard ==========

create or replace function public.assert_no_double_booking(
  p_load_id bigint,
  p_driver_id bigint,
  p_truck_id bigint,
  p_status public.load_status
)
returns void
language plpgsql
as $$
begin
  if p_status not in ('assigned', 'in_transit') then
    return;
  end if;
  if p_driver_id is not null and exists (
    select 1 from public.loads
     where driver_id = p_driver_id
       and status in ('assigned', 'in_transit')
       and id is distinct from p_load_id
  ) then
    raise exception 'Driver is already assigned to another active load';
  end if;
  if p_truck_id is not null and exists (
    select 1 from public.loads
     where truck_id = p_truck_id
       and status in ('assigned', 'in_transit')
       and id is distinct from p_load_id
  ) then
    raise exception 'Truck is already assigned to another active load';
  end if;
end;
$$;

create or replace function public.loads_before_insert()
returns trigger language plpgsql as $$
begin
  if new.load_number is null or new.load_number = '' then
    new.load_number := public.next_load_number();
  end if;
  if new.status = 'pending' and new.driver_id is not null and new.truck_id is not null then
    new.status := 'assigned';
  end if;
  perform public.assert_no_double_booking(null, new.driver_id, new.truck_id, new.status);
  return new;
end;
$$;

create or replace function public.loads_before_update()
returns trigger language plpgsql as $$
begin
  if current_setting('app.load_rpc', true) = '1' then
    perform public.assert_no_double_booking(new.id, new.driver_id, new.truck_id, new.status);
    return new;
  end if;
  if old.status = 'billed' then
    raise exception 'Billed loads are locked; void the invoice first';
  end if;
  if new.status is distinct from old.status then
    raise exception 'Use change_load_status() to move a load through the workflow';
  end if;
  if new.invoice_id is distinct from old.invoice_id then
    raise exception 'invoice_id is managed by create_invoice()/void_invoice()';
  end if;
  if new.status = 'pending' and new.driver_id is not null and new.truck_id is not null then
    new.status := 'assigned';
  end if;
  perform public.assert_no_double_booking(new.id, new.driver_id, new.truck_id, new.status);
  return new;
end;
$$;

-- ========== Driver ↔ profile link ==========

alter table public.drivers
  add column if not exists user_id uuid unique references public.profiles (id) on delete set null;

create index if not exists drivers_user_id_idx on public.drivers (user_id)
  where user_id is not null;

create or replace function public.drivers_user_id_guard()
returns trigger
language plpgsql
security definer set search_path = public
as $$
declare
  r public.user_role;
  active boolean;
begin
  if new.user_id is null then
    return new;
  end if;
  select role, is_active into r, active from public.profiles where id = new.user_id;
  if not found then
    raise exception 'Linked profile not found';
  end if;
  if r <> 'driver' then
    raise exception 'Linked profile must have role=driver';
  end if;
  if not active then
    raise exception 'Linked profile must be active';
  end if;
  return new;
end;
$$;

drop trigger if exists drivers_user_id_guard on public.drivers;
create trigger drivers_user_id_guard
  before insert or update of user_id on public.drivers
  for each row execute function public.drivers_user_id_guard();

create or replace function public.profiles_clear_driver_link()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  if (new.role is distinct from old.role and new.role <> 'driver')
     or (new.is_active is distinct from old.is_active and new.is_active = false) then
    update public.drivers set user_id = null where user_id = new.id;
  end if;
  return new;
end;
$$;

drop trigger if exists profiles_clear_driver_link on public.profiles;
create trigger profiles_clear_driver_link
  after update of role, is_active on public.profiles
  for each row execute function public.profiles_clear_driver_link();

create or replace function public.my_driver_id()
returns bigint
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  d_id bigint;
begin
  if auth.uid() is null then
    return null;
  end if;
  select id into d_id from public.drivers where user_id = auth.uid();
  return d_id;
end;
$$;

revoke all on function public.my_driver_id() from public;
revoke execute on function public.my_driver_id() from anon;
grant execute on function public.my_driver_id() to authenticated;

-- ========== Driver DTO RPCs (internal helper not granted) ==========

create or replace function public.driver_load_dto(p_load_id bigint)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'id', l.id,
    'load_number', l.load_number,
    'status', l.status,
    'pickup_address', l.pickup_address,
    'pickup_time', l.pickup_time,
    'delivery_address', l.delivery_address,
    'delivery_time', l.delivery_time,
    'special_terms', l.special_terms,
    'notes', l.notes,
    'miles', l.miles,
    'reference_number', l.reference_number,
    'pickup_number', l.pickup_number,
    'delivery_number', l.delivery_number,
    'customer_name', c.company_name,
    'truck_unit', t.unit_number,
    'trailer_unit', tr.unit_number,
    'driver_name', d.full_name
  )
  from public.loads l
  join public.customers c on c.id = l.customer_id
  left join public.trucks t on t.id = l.truck_id
  left join public.trailers tr on tr.id = l.trailer_id
  join public.drivers d on d.id = l.driver_id
  where l.id = p_load_id;
$$;

revoke all on function public.driver_load_dto(bigint) from public;
revoke all on function public.driver_load_dto(bigint) from anon, authenticated;

create or replace function public.driver_my_loads()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  d_id bigint := public.my_driver_id();
begin
  if public.my_role() <> 'driver' or d_id is null then
    raise exception 'Not a linked driver' using errcode = '42501';
  end if;

  return coalesce((
    select jsonb_agg(public.driver_load_dto(x.id) order by x.pickup_time nulls last)
    from (
      select l.id, l.pickup_time
        from public.loads l
       where l.driver_id = d_id
         and l.status in ('assigned', 'in_transit', 'delivered', 'completed')
    ) x
  ), '[]'::jsonb);
end;
$$;

revoke all on function public.driver_my_loads() from public;
revoke execute on function public.driver_my_loads() from anon;
grant execute on function public.driver_my_loads() to authenticated;

create or replace function public.driver_get_load(p_load_id bigint)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  d_id bigint := public.my_driver_id();
  owner bigint;
begin
  if public.my_role() <> 'driver' or d_id is null then
    raise exception 'Not enough permissions' using errcode = '42501';
  end if;
  select driver_id into owner from public.loads where id = p_load_id;
  if not found then
    raise exception 'Load not found' using errcode = 'P0002';
  end if;
  if owner is distinct from d_id then
    raise exception 'Not your load' using errcode = '42501';
  end if;
  return public.driver_load_dto(p_load_id);
end;
$$;

revoke all on function public.driver_get_load(bigint) from public;
revoke execute on function public.driver_get_load(bigint) from anon;
grant execute on function public.driver_get_load(bigint) to authenticated;

create or replace function public.driver_list_documents(p_load_id bigint)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  d_id bigint := public.my_driver_id();
  owner bigint;
begin
  if public.my_role() <> 'driver' or d_id is null then
    raise exception 'Not enough permissions' using errcode = '42501';
  end if;
  select driver_id into owner from public.loads where id = p_load_id;
  if not found then
    raise exception 'Load not found' using errcode = 'P0002';
  end if;
  if owner is distinct from d_id then
    raise exception 'Not your load' using errcode = '42501';
  end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', d.id,
      'doc_type', d.doc_type,
      'filename', d.filename,
      'content_type', d.content_type,
      'size_bytes', d.size_bytes,
      'uploaded_at', d.uploaded_at,
      'storage_path', d.storage_path
    ) order by d.uploaded_at desc)
    from public.documents d
    where d.entity_type = 'load' and d.entity_id = p_load_id
  ), '[]'::jsonb);
end;
$$;

revoke all on function public.driver_list_documents(bigint) from public;
revoke execute on function public.driver_list_documents(bigint) from anon;
grant execute on function public.driver_list_documents(bigint) to authenticated;

create or replace function public.driver_change_load_status(
  p_load_id bigint,
  p_status public.load_status
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  l public.loads;
  d_id bigint := public.my_driver_id();
  allowed boolean;
  prev public.load_status;
begin
  if public.my_role() <> 'driver' or d_id is null then
    raise exception 'Not enough permissions' using errcode = '42501';
  end if;

  select * into l from public.loads where id = p_load_id for update;
  if not found then
    raise exception 'Load not found' using errcode = 'P0002';
  end if;
  if l.driver_id is distinct from d_id then
    raise exception 'Not your load' using errcode = '42501';
  end if;

  prev := l.status;
  allowed :=
    (l.status = 'assigned' and p_status = 'in_transit')
    or (l.status = 'in_transit' and p_status = 'delivered');

  if not allowed then
    raise exception 'Driver cannot change status from % to %', l.status, p_status;
  end if;

  perform set_config('app.load_rpc', '1', true);
  update public.loads set status = p_status where id = p_load_id;
  perform set_config('app.load_rpc', '', true);

  insert into public.activity_log (entity_type, entity_id, user_id, action, detail)
  values (
    'load', p_load_id, auth.uid(), 'status_changed',
    'driver: ' || prev::text || ' → ' || p_status::text
  );

  return public.driver_load_dto(p_load_id);
end;
$$;

revoke all on function public.driver_change_load_status(bigint, public.load_status) from public;
revoke execute on function public.driver_change_load_status(bigint, public.load_status) from anon;
grant execute on function public.driver_change_load_status(bigint, public.load_status) to authenticated;

-- Duty
create table if not exists public.driver_duty (
  driver_id bigint primary key references public.drivers (id) on delete cascade,
  is_on_duty boolean not null default false,
  on_duty_since timestamptz,
  updated_at timestamptz not null default now(),
  updated_by uuid references public.profiles (id)
);

alter table public.driver_duty enable row level security;

drop policy if exists driver_duty_staff_select on public.driver_duty;
create policy driver_duty_staff_select on public.driver_duty
  for select to authenticated
  using (public.my_role() in ('admin', 'dispatcher', 'accountant'));

create or replace function public.driver_set_duty(p_on_duty boolean)
returns public.driver_duty
language plpgsql
security definer set search_path = public
as $$
declare
  d_id bigint := public.my_driver_id();
  row public.driver_duty;
begin
  if public.my_role() <> 'driver' or d_id is null then
    raise exception 'Not enough permissions';
  end if;
  if (select status from public.drivers where id = d_id) <> 'active' then
    raise exception 'Driver not active';
  end if;

  insert into public.driver_duty (driver_id, is_on_duty, on_duty_since, updated_by, updated_at)
  values (
    d_id, p_on_duty,
    case when p_on_duty then now() else null end,
    auth.uid(), now()
  )
  on conflict (driver_id) do update set
    is_on_duty = excluded.is_on_duty,
    on_duty_since = case when excluded.is_on_duty then coalesce(public.driver_duty.on_duty_since, now()) else null end,
    updated_by = excluded.updated_by,
    updated_at = now()
  returning * into row;
  return row;
end;
$$;

revoke all on function public.driver_set_duty(boolean) from public;
revoke execute on function public.driver_set_duty(boolean) from anon;
grant execute on function public.driver_set_duty(boolean) to authenticated;

-- ========== GPS ==========

create table if not exists public.vehicle_positions (
  id bigint generated always as identity primary key,
  driver_id bigint not null references public.drivers (id),
  truck_id bigint references public.trucks (id),
  load_id bigint references public.loads (id),
  user_id uuid not null references public.profiles (id),
  recorded_at timestamptz not null,
  received_at timestamptz not null default now(),
  lat double precision not null check (lat between -90 and 90),
  lng double precision not null check (lng between -180 and 180),
  speed_mps double precision,
  heading_deg double precision,
  accuracy_m double precision,
  battery_pct smallint,
  source text not null default 'companion_app',
  constraint vehicle_positions_recorded_not_future
    check (recorded_at <= now() + interval '5 minutes')
);

create index if not exists vehicle_positions_driver_time_idx
  on public.vehicle_positions (driver_id, recorded_at desc);
create index if not exists vehicle_positions_truck_time_idx
  on public.vehicle_positions (truck_id, recorded_at desc)
  where truck_id is not null;

create table if not exists public.vehicle_position_current (
  driver_id bigint primary key references public.drivers (id) on delete cascade,
  truck_id bigint references public.trucks (id),
  load_id bigint references public.loads (id),
  lat double precision not null,
  lng double precision not null,
  speed_mps double precision,
  heading_deg double precision,
  accuracy_m double precision,
  recorded_at timestamptz not null,
  updated_at timestamptz not null default now()
);

alter table public.vehicle_positions enable row level security;
alter table public.vehicle_position_current enable row level security;

drop policy if exists vpc_staff_select on public.vehicle_position_current;
create policy vpc_staff_select on public.vehicle_position_current
  for select to authenticated
  using (public.my_role() in ('admin', 'dispatcher', 'accountant'));

drop policy if exists vp_staff_select on public.vehicle_positions;
create policy vp_staff_select on public.vehicle_positions
  for select to authenticated
  using (public.my_role() in ('admin', 'dispatcher', 'accountant'));

drop policy if exists vpc_driver_select_own on public.vehicle_position_current;
create policy vpc_driver_select_own on public.vehicle_position_current
  for select to authenticated
  using (public.my_role() = 'driver' and driver_id = public.my_driver_id());

-- Realtime for fleet map
do $$
begin
  begin
    alter publication supabase_realtime add table public.vehicle_position_current;
  exception when duplicate_object then
    null;
  when undefined_object then
    null;
  end;
end;
$$;

-- Ingest: jsonb array of points, server-sorted by recorded_at
create or replace function public.ingest_vehicle_positions(p_points jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  d_id bigint := public.my_driver_id();
  pt jsonb;
  active_load public.loads;
  t_id bigint;
  load_id bigint;
  last_at timestamptz;
  accepted int := 0;
  rejected jsonb := '[]'::jsonb;
  min_interval interval := interval '45 seconds';
  skew interval := interval '5 minutes';
  i int := 0;
  v_lat double precision;
  v_lng double precision;
  v_recorded timestamptz;
  v_load_hint bigint;
begin
  if public.my_role() <> 'driver' or d_id is null then
    raise exception 'Only linked drivers may ingest positions' using errcode = '42501';
  end if;
  if (select status from public.drivers where id = d_id) <> 'active' then
    raise exception 'Driver not active' using errcode = '42501';
  end if;
  if p_points is null or jsonb_typeof(p_points) <> 'array' or jsonb_array_length(p_points) = 0 then
    raise exception 'No points' using errcode = '22023';
  end if;
  if jsonb_array_length(p_points) > 60 then
    raise exception 'Max 60 points per batch' using errcode = '22023';
  end if;

  select * into active_load
    from public.loads
   where driver_id = d_id
     and status in ('assigned', 'in_transit')
   order by
     case status when 'in_transit' then 0 else 1 end,
     pickup_time nulls last
   limit 1;

  if active_load.id is null then
    if not exists (
      select 1 from public.driver_duty where driver_id = d_id and is_on_duty
    ) then
      raise exception 'Not on duty and no active load' using errcode = '42501';
    end if;
    t_id := null;
    load_id := null;
  else
    t_id := active_load.truck_id;
    load_id := active_load.id;
  end if;

  select max(recorded_at) into last_at
    from public.vehicle_positions
   where driver_id = d_id
     and recorded_at > now() - interval '1 day';

  for pt in
    select value
      from jsonb_array_elements(p_points) as t(value)
     order by (value ->> 'recorded_at')::timestamptz asc nulls last
  loop
    i := i + 1;
    v_lat := (pt ->> 'lat')::double precision;
    v_lng := (pt ->> 'lng')::double precision;
    v_recorded := (pt ->> 'recorded_at')::timestamptz;
    v_load_hint := nullif(pt ->> 'load_id', '')::bigint;

    if v_lat is null or v_lng is null or v_recorded is null then
      rejected := rejected || jsonb_build_array(jsonb_build_object('i', i, 'error', 'missing_fields'));
      continue;
    end if;
    if v_lat < -90 or v_lat > 90 or v_lng < -180 or v_lng > 180 then
      rejected := rejected || jsonb_build_array(jsonb_build_object('i', i, 'error', 'bad_coords'));
      continue;
    end if;
    if v_recorded > now() + skew then
      rejected := rejected || jsonb_build_array(jsonb_build_object('i', i, 'error', 'future_timestamp'));
      continue;
    end if;
    if v_recorded < now() - interval '24 hours' then
      rejected := rejected || jsonb_build_array(jsonb_build_object('i', i, 'error', 'too_old'));
      continue;
    end if;
    if v_load_hint is not null and load_id is not null and v_load_hint is distinct from load_id then
      rejected := rejected || jsonb_build_array(jsonb_build_object('i', i, 'error', 'load_mismatch'));
      continue;
    end if;
    if last_at is not null and v_recorded < last_at + min_interval then
      rejected := rejected || jsonb_build_array(jsonb_build_object('i', i, 'error', 'too_frequent'));
      continue;
    end if;

    insert into public.vehicle_positions (
      driver_id, truck_id, load_id, user_id, recorded_at,
      lat, lng, speed_mps, heading_deg, accuracy_m, battery_pct
    ) values (
      d_id, t_id, load_id, auth.uid(), v_recorded,
      v_lat, v_lng,
      nullif(pt ->> 'speed_mps', '')::double precision,
      nullif(pt ->> 'heading_deg', '')::double precision,
      nullif(pt ->> 'accuracy_m', '')::double precision,
      nullif(pt ->> 'battery_pct', '')::smallint
    );

    insert into public.vehicle_position_current as c (
      driver_id, truck_id, load_id, lat, lng, speed_mps, heading_deg, accuracy_m, recorded_at, updated_at
    ) values (
      d_id, t_id, load_id, v_lat, v_lng,
      nullif(pt ->> 'speed_mps', '')::double precision,
      nullif(pt ->> 'heading_deg', '')::double precision,
      nullif(pt ->> 'accuracy_m', '')::double precision,
      v_recorded, now()
    )
    on conflict (driver_id) do update set
      truck_id = excluded.truck_id,
      load_id = excluded.load_id,
      lat = excluded.lat,
      lng = excluded.lng,
      speed_mps = excluded.speed_mps,
      heading_deg = excluded.heading_deg,
      accuracy_m = excluded.accuracy_m,
      recorded_at = excluded.recorded_at,
      updated_at = now()
    where c.recorded_at is distinct from excluded.recorded_at
      and c.recorded_at < excluded.recorded_at;

    last_at := v_recorded;
    accepted := accepted + 1;
  end loop;

  return jsonb_build_object('accepted', accepted, 'rejected', rejected);
end;
$$;

revoke all on function public.ingest_vehicle_positions(jsonb) from public;
revoke execute on function public.ingest_vehicle_positions(jsonb) from anon;
grant execute on function public.ingest_vehicle_positions(jsonb) to authenticated;

-- Staff fleet pins with names (DEFINER, office roles only)
create or replace function public.fleet_positions_snapshot()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if public.my_role() not in ('admin', 'dispatcher', 'accountant') then
    raise exception 'Not enough permissions';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'driver_id', c.driver_id,
      'driver_name', d.full_name,
      'truck_id', c.truck_id,
      'truck_unit', t.unit_number,
      'load_id', c.load_id,
      'load_number', l.load_number,
      'lat', c.lat,
      'lng', c.lng,
      'speed_mps', c.speed_mps,
      'heading_deg', c.heading_deg,
      'recorded_at', c.recorded_at
    ) order by d.full_name)
    from public.vehicle_position_current c
    join public.drivers d on d.id = c.driver_id
    left join public.trucks t on t.id = c.truck_id
    left join public.loads l on l.id = c.load_id
  ), '[]'::jsonb);
end;
$$;

revoke all on function public.fleet_positions_snapshot() from public;
revoke execute on function public.fleet_positions_snapshot() from anon;
grant execute on function public.fleet_positions_snapshot() to authenticated;

-- ========== Push devices ==========

create table if not exists public.push_devices (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles (id) on delete cascade,
  platform text not null check (platform in ('ios','android')),
  token text not null,
  updated_at timestamptz not null default now(),
  unique (user_id, token)
);

alter table public.push_devices enable row level security;

drop policy if exists push_devices_own on public.push_devices;
create policy push_devices_own on public.push_devices
  for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());
