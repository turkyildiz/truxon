-- Phase 0 driver linkage + companion driver RPCs
-- PR7: drivers.user_id + my_driver_id + integrity triggers
-- PR8: driver DTO RPCs + driver_change_load_status + driver_duty

-- ========== PR7: link drivers to auth profiles ==========

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
grant execute on function public.my_driver_id() to authenticated;

-- ========== PR8: driver DTOs + status + duty ==========

-- INTERNAL only — no grant to authenticated/anon
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
grant execute on function public.driver_change_load_status(bigint, public.load_status) to authenticated;

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
grant execute on function public.driver_set_duty(boolean) to authenticated;
