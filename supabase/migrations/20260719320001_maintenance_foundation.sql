-- Maintenance module, phase 1 — foundation.
--
-- Today maintenance_records is a thin repair log (a receipt drawer): cost +
-- shop free-text, consumed only as SUM(cost) by the P&L / scorecard. This phase
-- turns it into a real MX record without breaking those consumers:
--   * service_type + status + is_planned  -> categorize & tell planned vs reactive
--   * odometer                            -> mileage at service (manual override)
--   * vendor_id -> maintenance_vendors    -> track outsourced-shop spend cleanly
--   * current_odometer / fleet_odometers  -> current mileage, derived HONESTLY
--     from the fuel-card odometer readings we already ingest (no new hardware,
--     no manual mileage discipline required). This is the bridge that makes the
--     mileage-based PM engine (phase 2) possible.
--
-- The existing cost path is untouched: pnl_summary / company_scorecard still
-- read cost + date_completed, which keep their meaning.

-- ---------- enums ----------
do $$ begin
  create type public.maintenance_service_type as enum (
    'pm_service','oil_lube','tires','brakes','engine','drivetrain',
    'electrical','cooling','aftertreatment','dot_inspection','bodywork',
    'roadside','other');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.maintenance_status as enum (
    'scheduled','in_progress','completed','cancelled');
exception when duplicate_object then null; end $$;

-- ---------- vendors (outsourced shops) ----------
create table if not exists public.maintenance_vendors (
  id bigint generated always as identity primary key,
  name text not null unique,
  phone text not null default '',
  city text not null default '',
  state text not null default '',
  specialty text not null default '',      -- e.g. "tires", "engine", "mobile"
  notes text not null default '',
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.maintenance_vendors enable row level security;
drop policy if exists maintenance_vendors_read on public.maintenance_vendors;
create policy maintenance_vendors_read on public.maintenance_vendors
  for select to authenticated
  using (public.my_role() in ('admin','dispatcher','accountant','maintenance'));
drop policy if exists maintenance_vendors_write on public.maintenance_vendors;
create policy maintenance_vendors_write on public.maintenance_vendors
  for all to authenticated
  using (public.my_role() in ('admin','dispatcher','maintenance'))
  with check (public.my_role() in ('admin','dispatcher','maintenance'));

drop trigger if exists maintenance_vendors_touch on public.maintenance_vendors;
create trigger maintenance_vendors_touch before update on public.maintenance_vendors
  for each row execute function public.touch_updated_at();

-- ---------- enrich maintenance_records ----------
alter table public.maintenance_records
  add column if not exists service_type public.maintenance_service_type not null default 'other',
  add column if not exists status public.maintenance_status not null default 'completed',
  add column if not exists odometer bigint,                 -- miles at service (nullable)
  add column if not exists is_planned boolean not null default false,
  add column if not exists scheduled_date date,             -- for status='scheduled'
  add column if not exists vendor_id bigint references public.maintenance_vendors (id),
  add column if not exists invoice_ref text not null default '';   -- shop invoice #

-- Backfill: a row with a completion date is completed; otherwise it's still open.
update public.maintenance_records
   set status = case when date_completed is not null
                     then 'completed'::public.maintenance_status
                     else 'scheduled'::public.maintenance_status end
 where status is null or status = 'completed';   -- only touch rows on the default

create index if not exists maintenance_truck_idx on public.maintenance_records (truck_id, date_completed desc);
create index if not exists maintenance_trailer_idx on public.maintenance_records (trailer_id, date_completed desc);
create index if not exists maintenance_service_type_idx on public.maintenance_records (service_type);
create index if not exists maintenance_vendor_idx on public.maintenance_records (vendor_id);
create index if not exists maintenance_open_idx on public.maintenance_records (status)
  where status in ('scheduled','in_progress');

-- ---------- current mileage, from fuel-card odometer readings ----------
-- The most recent plausible odometer reading for a truck. Prefer the telematics
-- reading over the driver-prompted one (fewer fat-finger errors); ignore zeros.
-- SECURITY DEFINER so it can read fuel_transactions for the maintenance role
-- (which reads odometer here but never sees fuel cost).
create or replace function public.current_odometer(p_truck_id bigint)
returns bigint
language sql stable security definer set search_path = public as $$
  select reading from (
    select coalesce(nullif(f.telematics_odometer,0), nullif(f.prompted_odometer,0)) as reading,
           f.transaction_time
      from public.fuel_transactions f
     where f.truck_id = p_truck_id
       and (public.my_role() in ('admin','accountant','dispatcher','maintenance') or auth.role() = 'service_role')
       and coalesce(nullif(f.telematics_odometer,0), nullif(f.prompted_odometer,0)) is not null
     order by f.transaction_time desc
     limit 1
  ) x;
$$;

-- Whole-fleet current odometer + when it was last read (so the UI can flag a
-- stale reading — a truck that hasn't fueled in a while).
create or replace function public.fleet_odometers()
returns table (truck_id bigint, unit_number text, odometer bigint, reading_date timestamptz)
language sql stable security definer set search_path = public as $$
  select t.id, t.unit_number, r.reading, r.transaction_time
    from public.trucks t
    left join lateral (
      select coalesce(nullif(f.telematics_odometer,0), nullif(f.prompted_odometer,0)) as reading,
             f.transaction_time
        from public.fuel_transactions f
       where f.truck_id = t.id
         and coalesce(nullif(f.telematics_odometer,0), nullif(f.prompted_odometer,0)) is not null
       order by f.transaction_time desc
       limit 1
    ) r on true
   where (public.my_role() in ('admin','accountant','dispatcher','maintenance') or auth.role() = 'service_role')
     and t.status <> 'retired'
   order by t.unit_number;
$$;

revoke execute on function public.current_odometer(bigint) from public, anon;
revoke execute on function public.fleet_odometers() from public, anon;
grant execute on function public.current_odometer(bigint) to authenticated;
grant execute on function public.fleet_odometers() to authenticated;
