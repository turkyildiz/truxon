-- Maintenance module, phase 2 — preventive-maintenance & compliance engine.
--
-- pm_programs defines the recurring services Aida runs, each on a mileage
-- interval, a time interval, or BOTH (whichever comes first — standard fleet
-- practice). maintenance_due() then computes, per unit per program, how much
-- mileage/time is left before the next service, using current_odometer() (the
-- fuel-card bridge from phase 1) for the mileage side. maintenance_alerts()
-- unions PM/inspection due + plate-registration expiry + stale open work orders
-- into one "needs attention" feed — the thing a remote owner actually wants.
--
-- Honesty: when a program is mileage-based but a unit has no odometer reading
-- (trailers, or a truck that hasn't fueled), that dimension reports 'unknown'
-- rather than a fabricated due date.

-- ---------- program definitions ----------
create table if not exists public.pm_programs (
  id bigint generated always as identity primary key,
  name text not null unique,
  applies_to text not null default 'truck' check (applies_to in ('truck','trailer','all')),
  service_type public.maintenance_service_type not null default 'pm_service',
  interval_miles int,
  interval_days int,
  is_active boolean not null default true,
  notes text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint pm_interval_present check (interval_miles is not null or interval_days is not null),
  constraint pm_interval_positive check (
    (interval_miles is null or interval_miles > 0) and
    (interval_days is null or interval_days > 0))
);

alter table public.pm_programs enable row level security;
drop policy if exists pm_programs_read on public.pm_programs;
create policy pm_programs_read on public.pm_programs
  for select to authenticated
  using (public.my_role() in ('admin','dispatcher','accountant','maintenance'));
-- Program definitions are maintenance policy: admin or the maintenance role own them.
drop policy if exists pm_programs_write on public.pm_programs;
create policy pm_programs_write on public.pm_programs
  for all to authenticated
  using (public.my_role() in ('admin','maintenance'))
  with check (public.my_role() in ('admin','maintenance'));

drop trigger if exists pm_programs_touch on public.pm_programs;
create trigger pm_programs_touch before update on public.pm_programs
  for each row execute function public.touch_updated_at();

-- Link a completed service to the program it satisfies (optional — historical
-- rows match by service_type instead).
alter table public.maintenance_records
  add column if not exists pm_program_id bigint references public.pm_programs (id);
create index if not exists maintenance_pm_program_idx
  on public.maintenance_records (pm_program_id, date_completed desc);

-- ---------- seed Aida's standard programs (editable in the UI) ----------
insert into public.pm_programs (name, applies_to, service_type, interval_miles, interval_days, notes) values
  ('PM Service (A)',          'truck',   'pm_service',     25000, 180, 'Full preventive service — oil, filters, inspection'),
  ('DOT Annual Inspection',   'all',     'dot_inspection', null,  365, 'Federal annual DOT inspection (49 CFR 396.17)'),
  ('Tire Service',            'truck',   'tires',          50000, null,'Rotation / replacement check'),
  ('Trailer Annual Service',  'trailer', 'pm_service',     null,  180, 'Trailer PM & brake check')
on conflict (name) do nothing;

-- ---------- the due engine ----------
-- For every active program × applicable in-service unit, find the most recent
-- completed matching service (by explicit program link, else by service_type),
-- then compute miles/days remaining and a single due_status = worst dimension.
create or replace function public.maintenance_due()
returns table (
  equipment_type text, unit_id bigint, unit_number text,
  program_id bigint, program_name text, service_type text,
  interval_miles int, interval_days int,
  last_service_date date, last_service_odometer bigint,
  current_odometer bigint, miles_since bigint, days_since int,
  miles_remaining bigint, days_remaining int, due_status text
)
language sql stable security definer set search_path = public as $$
  with units as (
    select 'truck'::text et, t.id, t.unit_number, public.current_odometer(t.id) as cur_odo
      from public.trucks t where t.status <> 'retired'
    union all
    select 'trailer'::text, tr.id, tr.unit_number, null::bigint
      from public.trailers tr where tr.status <> 'retired'
  ),
  pairs as (
    select p.id pid, p.name pname, p.service_type::text stype,
           p.interval_miles, p.interval_days,
           u.et, u.id uid, u.unit_number, u.cur_odo
      from public.pm_programs p
      join units u on p.applies_to = 'all' or p.applies_to = u.et
     where p.is_active
  ),
  last_svc as (
    select pr.pid, pr.uid, pr.et,
      (select m.date_completed from public.maintenance_records m
        where m.status = 'completed'
          and (m.pm_program_id = pr.pid or (m.pm_program_id is null and m.service_type::text = pr.stype))
          and ((pr.et = 'truck'   and m.truck_id   = pr.uid)
            or (pr.et = 'trailer' and m.trailer_id = pr.uid))
        order by m.date_completed desc nulls last, m.id desc limit 1) as ldate,
      (select m.odometer from public.maintenance_records m
        where m.status = 'completed' and m.odometer is not null
          and (m.pm_program_id = pr.pid or (m.pm_program_id is null and m.service_type::text = pr.stype))
          and ((pr.et = 'truck'   and m.truck_id   = pr.uid)
            or (pr.et = 'trailer' and m.trailer_id = pr.uid))
        order by m.date_completed desc nulls last, m.id desc limit 1) as lodo
    from pairs pr
  )
  select pr.et, pr.uid, pr.unit_number, pr.pid, pr.pname, pr.stype,
         pr.interval_miles, pr.interval_days,
         ls.ldate, ls.lodo, pr.cur_odo,
         case when pr.cur_odo is not null and ls.lodo is not null then pr.cur_odo - ls.lodo end,
         case when ls.ldate is not null then (current_date - ls.ldate) end,
         case when pr.interval_miles is not null and pr.cur_odo is not null and ls.lodo is not null
              then pr.interval_miles - (pr.cur_odo - ls.lodo) end,
         case when pr.interval_days is not null and ls.ldate is not null
              then pr.interval_days - (current_date - ls.ldate) end,
         case
           when ls.ldate is null and ls.lodo is null then 'never_serviced'
           when (pr.interval_miles is not null and pr.cur_odo is not null and ls.lodo is not null
                 and pr.interval_miles - (pr.cur_odo - ls.lodo) <= 0)
             or (pr.interval_days is not null and ls.ldate is not null
                 and pr.interval_days - (current_date - ls.ldate) <= 0) then 'overdue'
           when (pr.interval_miles is not null and pr.cur_odo is not null and ls.lodo is not null
                 and pr.interval_miles - (pr.cur_odo - ls.lodo) <= 1500)
             or (pr.interval_days is not null and ls.ldate is not null
                 and pr.interval_days - (current_date - ls.ldate) <= 21) then 'due_soon'
           when (pr.interval_miles is null or pr.cur_odo is null or ls.lodo is null)
            and (pr.interval_days is null or ls.ldate is null) then 'unknown'
           else 'ok'
         end as due_status
    from pairs pr join last_svc ls on ls.pid = pr.pid and ls.uid = pr.uid
   where public.my_role() in ('admin','dispatcher','accountant','maintenance') or auth.role() = 'service_role'
   order by pr.unit_number, pr.pname;
$$;

-- ---------- unified "needs attention" feed ----------
create or replace function public.maintenance_alerts()
returns table (
  kind text, severity text, equipment_type text, unit_id bigint,
  unit_number text, label text, detail text, due_date date, category text
)
language sql stable security definer set search_path = public as $$
  select al.kind, al.severity, al.equipment_type, al.unit_id, al.unit_number,
         al.label, al.detail, al.due_date, al.category
  from (
    -- PM / inspection due
    select 'pm'::text as kind,
           case when d.due_status in ('overdue','never_serviced') then 'overdue'
                when d.due_status = 'due_soon' then 'due_soon' else 'info' end as severity,
           d.equipment_type, d.unit_id, d.unit_number, d.program_name as label,
           case when d.due_status = 'never_serviced' then 'never recorded — baseline needed'
                when d.miles_remaining is not null and d.miles_remaining <= 0 then 'over by '||abs(d.miles_remaining)||' mi'
                when d.days_remaining  is not null and d.days_remaining  <= 0 then 'over by '||abs(d.days_remaining)||' days'
                when d.miles_remaining is not null then d.miles_remaining||' mi left'
                when d.days_remaining  is not null then d.days_remaining||' days left'
                else 'unknown' end as detail,
           case when d.days_remaining is not null then current_date + d.days_remaining end as due_date,
           d.service_type as category
      from public.maintenance_due() d
     where d.due_status in ('overdue','due_soon','never_serviced')
    union all
    -- plate / registration expiring within 45 days (or already expired)
    select 'plate',
           case when x.plate_expiry < current_date then 'overdue' else 'due_soon' end,
           x.et, x.id, x.unit_number, 'Plate / registration',
           case when x.plate_expiry < current_date then 'expired '||(current_date - x.plate_expiry)||' days ago'
                else 'expires in '||(x.plate_expiry - current_date)||' days' end,
           x.plate_expiry, 'registration'
      from (
        select 'truck'::text et, id, unit_number, plate_expiry from public.trucks
         where status <> 'retired' and plate_expiry is not null
        union all
        select 'trailer', id, unit_number, plate_expiry from public.trailers
         where status <> 'retired' and plate_expiry is not null
      ) x
     where (public.my_role() in ('admin','dispatcher','accountant','maintenance') or auth.role() = 'service_role')
       and x.plate_expiry <= current_date + 45
    union all
    -- work orders left open too long
    select 'open_wo', 'due_soon', m.equipment_type::text,
           coalesce(m.truck_id, m.trailer_id),
           coalesce(t.unit_number, tr.unit_number), 'Open work order',
           coalesce(nullif(m.description,''),'(no description)')||' — open '||(current_date - m.created_at::date)||' days',
           null::date, m.service_type::text
      from public.maintenance_records m
      left join public.trucks t on t.id = m.truck_id
      left join public.trailers tr on tr.id = m.trailer_id
     where (public.my_role() in ('admin','dispatcher','accountant','maintenance') or auth.role() = 'service_role')
       and m.status in ('scheduled','in_progress')
       and m.created_at < now() - interval '7 days'
  ) al
  order by case al.severity when 'overdue' then 0 when 'due_soon' then 1 else 2 end, al.unit_number;
$$;

revoke execute on function public.maintenance_due() from public, anon;
revoke execute on function public.maintenance_alerts() from public, anon;
grant execute on function public.maintenance_due() to authenticated;
grant execute on function public.maintenance_alerts() to authenticated;
