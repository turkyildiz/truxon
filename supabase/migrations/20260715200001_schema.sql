-- TrucksOn TMS — core schema
-- Business rules live in the database so any client (web, future mobile)
-- gets identical behavior.

-- ---------- Enums ----------

create type public.user_role as enum ('admin', 'dispatcher', 'driver', 'accountant', 'maintenance');
create type public.driver_status as enum ('active', 'inactive', 'terminated');
create type public.equipment_status as enum ('available', 'in_use', 'maintenance', 'retired');
create type public.equipment_type as enum ('truck', 'trailer');
create type public.load_status as enum ('pending', 'assigned', 'in_transit', 'delivered', 'completed', 'billed');
create type public.invoice_status as enum ('draft', 'sent', 'paid');

-- ---------- Profiles (one per auth user) ----------

create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  username text not null unique,
  full_name text not null default '',
  role public.user_role not null default 'dispatcher',
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

-- Role of the calling user; security definer so RLS policies can use it
-- without recursing into profiles' own policies.
create or replace function public.my_role()
returns public.user_role
language sql stable security definer set search_path = public
as $$
  select role from public.profiles where id = auth.uid();
$$;

-- Auto-create a profile when a user signs up / is created by the admin
-- edge function (role and names arrive in raw_user_meta_data).
create or replace function public.handle_new_user()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  insert into public.profiles (id, username, full_name, role)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'username', split_part(new.email, '@', 1)),
    coalesce(new.raw_user_meta_data ->> 'full_name', ''),
    coalesce((new.raw_user_meta_data ->> 'role')::public.user_role, 'dispatcher')
  );
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- Domain tables ----------

create table public.customers (
  id bigint generated always as identity primary key,
  company_name text not null,
  contact_person text not null default '',
  phone text not null default '',
  email text not null default '',
  billing_address text not null default '',
  payment_terms text not null default 'Net 30',
  notes text not null default '',
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.drivers (
  id bigint generated always as identity primary key,
  full_name text not null,
  license_number text not null default '',
  license_expiration date,
  date_of_birth date,
  hire_date date,
  pay_per_mile numeric(6,3) not null default 0,
  status public.driver_status not null default 'active',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.trucks (
  id bigint generated always as identity primary key,
  unit_number text not null unique,
  make text not null default '',
  model text not null default '',
  year int,
  vin text not null default '',
  in_service_date date,
  out_of_service_date date,
  monthly_cost numeric(10,2) not null default 0,
  status public.equipment_status not null default 'available',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.trailers (
  id bigint generated always as identity primary key,
  unit_number text not null unique,
  make text not null default '',
  model text not null default '',
  year int,
  vin text not null default '',
  in_service_date date,
  out_of_service_date date,
  monthly_cost numeric(10,2) not null default 0,
  status public.equipment_status not null default 'available',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.maintenance_records (
  id bigint generated always as identity primary key,
  equipment_type public.equipment_type not null,
  truck_id bigint references public.trucks (id),
  trailer_id bigint references public.trailers (id),
  date_completed date,
  description text not null default '',
  cost numeric(10,2) not null default 0,
  technician_shop text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint maintenance_equipment_link check (
    (equipment_type = 'truck' and truck_id is not null)
    or (equipment_type = 'trailer' and trailer_id is not null)
  )
);

create table public.invoices (
  id bigint generated always as identity primary key,
  invoice_number text not null unique,
  customer_id bigint not null references public.customers (id),
  invoice_date timestamptz not null default now(),
  due_date timestamptz,
  total numeric(12,2) not null default 0,
  status public.invoice_status not null default 'draft',
  created_at timestamptz not null default now()
);

create table public.loads (
  id bigint generated always as identity primary key,
  load_number text not null unique,
  customer_id bigint not null references public.customers (id),
  status public.load_status not null default 'pending',
  pickup_address text not null default '',
  pickup_time timestamptz,
  delivery_address text not null default '',
  delivery_time timestamptz,
  driver_id bigint references public.drivers (id),
  truck_id bigint references public.trucks (id),
  trailer_id bigint references public.trailers (id),
  rate numeric(10,2) not null default 0,
  miles numeric(8,1) not null default 0,
  special_terms text not null default '',
  notes text not null default '',
  invoice_id bigint references public.invoices (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index loads_customer_idx on public.loads (customer_id);
create index loads_status_idx on public.loads (status);
create index loads_driver_idx on public.loads (driver_id);

create table public.documents (
  id bigint generated always as identity primary key,
  entity_type text not null check (entity_type in ('load','driver','truck','trailer','customer','maintenance')),
  entity_id bigint not null,
  doc_type text not null default '',
  filename text not null,
  storage_path text not null,
  content_type text not null default 'application/octet-stream',
  size_bytes bigint not null default 0,
  uploaded_by uuid references public.profiles (id),
  uploaded_at timestamptz not null default now()
);

create index documents_entity_idx on public.documents (entity_type, entity_id);

create table public.activity_log (
  id bigint generated always as identity primary key,
  entity_type text not null,
  entity_id bigint not null,
  user_id uuid references public.profiles (id),
  action text not null,
  detail text not null default '',
  created_at timestamptz not null default now()
);

create index activity_entity_idx on public.activity_log (entity_type, entity_id);

-- ---------- Generic triggers ----------

create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger customers_touch before update on public.customers for each row execute function public.touch_updated_at();
create trigger drivers_touch before update on public.drivers for each row execute function public.touch_updated_at();
create trigger trucks_touch before update on public.trucks for each row execute function public.touch_updated_at();
create trigger trailers_touch before update on public.trailers for each row execute function public.touch_updated_at();
create trigger maintenance_touch before update on public.maintenance_records for each row execute function public.touch_updated_at();
create trigger loads_touch before update on public.loads for each row execute function public.touch_updated_at();

-- Audit: log inserts on major tables automatically.
create or replace function public.log_insert()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.activity_log (entity_type, entity_id, user_id, action, detail)
  values (tg_argv[0], new.id, auth.uid(), 'created', '');
  return new;
end;
$$;

create trigger customers_audit after insert on public.customers for each row execute function public.log_insert('customer');
create trigger drivers_audit after insert on public.drivers for each row execute function public.log_insert('driver');
create trigger trucks_audit after insert on public.trucks for each row execute function public.log_insert('truck');
create trigger trailers_audit after insert on public.trailers for each row execute function public.log_insert('trailer');
create trigger maintenance_audit after insert on public.maintenance_records for each row execute function public.log_insert('maintenance');

-- ---------- Load lifecycle rules ----------

create or replace function public.next_load_number()
returns text language plpgsql as $$
declare
  prefix text := 'LD-' || extract(year from now())::text || '-';
  seq int;
begin
  select coalesce(max(substring(load_number from length(prefix) + 1)::int), 0) + 1
    into seq
    from public.loads
   where load_number like prefix || '%';
  return prefix || lpad(seq::text, 4, '0');
end;
$$;

create or replace function public.next_invoice_number()
returns text language plpgsql as $$
declare
  prefix text := 'INV-' || extract(year from now())::text || '-';
  seq int;
begin
  select coalesce(max(substring(invoice_number from length(prefix) + 1)::int), 0) + 1
    into seq
    from public.invoices
   where invoice_number like prefix || '%';
  return prefix || lpad(seq::text, 4, '0');
end;
$$;

-- BEFORE INSERT: assign load number; a load created with driver+truck starts assigned.
create or replace function public.loads_before_insert()
returns trigger language plpgsql as $$
begin
  if new.load_number is null or new.load_number = '' then
    new.load_number := public.next_load_number();
  end if;
  if new.status = 'pending' and new.driver_id is not null and new.truck_id is not null then
    new.status := 'assigned';
  end if;
  return new;
end;
$$;

create trigger loads_before_insert before insert on public.loads
  for each row execute function public.loads_before_insert();

-- BEFORE UPDATE: billed loads are locked (only the RPCs, which set a session
-- flag, may modify them); auto-advance pending → assigned once staffed;
-- direct status jumps are rejected — status moves only via change_load_status().
create or replace function public.loads_before_update()
returns trigger language plpgsql as $$
begin
  if current_setting('app.load_rpc', true) = '1' then
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
  return new;
end;
$$;

create trigger loads_before_update before update on public.loads
  for each row execute function public.loads_before_update();

-- AFTER INSERT/UPDATE: trucks & trailers show in_use while their load is active.
create or replace function public.sync_equipment_status()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  active boolean := new.status in ('assigned', 'in_transit');
begin
  if new.truck_id is not null then
    update public.trucks set status = case when active then 'in_use' else 'available' end::public.equipment_status
     where id = new.truck_id and status not in ('maintenance', 'retired');
  end if;
  if new.trailer_id is not null then
    update public.trailers set status = case when active then 'in_use' else 'available' end::public.equipment_status
     where id = new.trailer_id and status not in ('maintenance', 'retired');
  end if;
  -- Release equipment that was swapped off the load.
  if tg_op = 'UPDATE' then
    if old.truck_id is not null and old.truck_id is distinct from new.truck_id then
      update public.trucks set status = 'available' where id = old.truck_id and status = 'in_use';
    end if;
    if old.trailer_id is not null and old.trailer_id is distinct from new.trailer_id then
      update public.trailers set status = 'available' where id = old.trailer_id and status = 'in_use';
    end if;
  end if;
  return new;
end;
$$;

create trigger loads_sync_equipment after insert or update on public.loads
  for each row execute function public.sync_equipment_status();

-- AFTER INSERT: audit new loads with their number.
create or replace function public.loads_audit_insert()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.activity_log (entity_type, entity_id, user_id, action, detail)
  values ('load', new.id, auth.uid(), 'created', 'Load ' || new.load_number || ' created with status ' || new.status);
  return new;
end;
$$;

create trigger loads_audit after insert on public.loads
  for each row execute function public.loads_audit_insert();

-- AFTER UPDATE: audit which fields changed.
create or replace function public.loads_audit_update()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  changed text[] := '{}';
begin
  if new.customer_id is distinct from old.customer_id then changed := changed || 'customer'; end if;
  if new.pickup_address is distinct from old.pickup_address then changed := changed || 'pickup_address'; end if;
  if new.pickup_time is distinct from old.pickup_time then changed := changed || 'pickup_time'; end if;
  if new.delivery_address is distinct from old.delivery_address then changed := changed || 'delivery_address'; end if;
  if new.delivery_time is distinct from old.delivery_time then changed := changed || 'delivery_time'; end if;
  if new.driver_id is distinct from old.driver_id then changed := changed || 'driver'; end if;
  if new.truck_id is distinct from old.truck_id then changed := changed || 'truck'; end if;
  if new.trailer_id is distinct from old.trailer_id then changed := changed || 'trailer'; end if;
  if new.rate is distinct from old.rate then changed := changed || 'rate'; end if;
  if new.miles is distinct from old.miles then changed := changed || 'miles'; end if;
  if array_length(changed, 1) > 0 then
    insert into public.activity_log (entity_type, entity_id, user_id, action, detail)
    values ('load', new.id, auth.uid(), 'updated', 'Changed: ' || array_to_string(changed, ', '));
  end if;
  return new;
end;
$$;

create trigger loads_audit_update after update on public.loads
  for each row execute function public.loads_audit_update();
