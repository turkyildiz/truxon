-- TABLET DAY — DVIR: driver vehicle inspection reports, in-app. Pre/post-trip
-- checklist posts here; any defect immediately becomes an unplanned
-- maintenance_records item (needs_review) so it lands in the MX command
-- center, and an unsafe verdict is loud. Inspection records are append-only.
-- 'dvir' joins the allowed maintenance sources
alter table public.maintenance_records drop constraint if exists maintenance_records_source_check;
alter table public.maintenance_records add constraint maintenance_records_source_check
  check (source in ('manual', 'email', 'api', 'dvir'));

create table public.dvir (
  id bigint generated always as identity primary key,
  driver_id bigint not null references public.drivers (id) on delete cascade,
  truck_id bigint not null references public.trucks (id) on delete cascade,
  inspection_type text not null check (inspection_type in ('pre_trip', 'post_trip')),
  odometer numeric,
  items jsonb not null,                 -- {"brakes":"ok","lights":"defect",...}
  defects text not null default '',     -- free-text description of what's wrong
  safe_to_operate boolean not null default true,
  created_at timestamptz not null default now()
);
create index dvir_truck_idx on public.dvir (truck_id, created_at desc);
alter table public.dvir enable row level security;

create policy dvir_select on public.dvir
  for select to authenticated
  using (
    public.my_role() in ('admin', 'dispatcher', 'accountant', 'maintenance')
    or driver_id = public.my_driver_id()
  );
-- inserts go through submit_dvir only (definer validates + wires defects)

create function public.submit_dvir(
  p_truck_id bigint,
  p_inspection_type text,
  p_items jsonb,
  p_odometer numeric default null,
  p_defects text default '',
  p_safe boolean default true
)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  d_id bigint := public.my_driver_id();
  v_id bigint;
  v_unit text;
  v_defect_items text;
begin
  if public.my_role() <> 'driver' or d_id is null then
    raise exception 'Not enough permissions' using errcode = '42501';
  end if;
  if p_inspection_type not in ('pre_trip', 'post_trip') then
    raise exception 'Invalid inspection type' using errcode = '22023';
  end if;
  select unit_number into v_unit from trucks where id = p_truck_id;
  if not found then
    raise exception 'Truck not found' using errcode = 'P0002';
  end if;

  insert into dvir (driver_id, truck_id, inspection_type, odometer, items, defects, safe_to_operate)
  values (d_id, p_truck_id, p_inspection_type, p_odometer, coalesce(p_items, '{}'::jsonb),
          coalesce(p_defects, ''), coalesce(p_safe, true))
  returning id into v_id;

  -- Any non-ok item or defect note → unplanned MX item for the command center.
  select string_agg(key, ', ') into v_defect_items
    from jsonb_each_text(coalesce(p_items, '{}'::jsonb)) where value <> 'ok';
  if v_defect_items is not null or coalesce(p_defects, '') <> '' or not coalesce(p_safe, true) then
    insert into maintenance_records
      (equipment_type, truck_id, description, cost, is_planned, status,
       service_type, scheduled_date, odometer, source, needs_review)
    values
      ('truck', p_truck_id,
       format('DVIR %s defect — unit %s: %s%s%s',
              replace(p_inspection_type, '_', '-'), v_unit,
              coalesce(v_defect_items, 'see note'),
              case when coalesce(p_defects, '') <> '' then '. ' || p_defects else '' end,
              case when not coalesce(p_safe, true) then ' [DRIVER MARKED NOT SAFE TO OPERATE]' else '' end),
       0, false, 'scheduled', 'other', current_date, p_odometer, 'dvir', true);
  end if;

  return jsonb_build_object('id', v_id, 'defect_flagged',
    v_defect_items is not null or coalesce(p_defects, '') <> '' or not coalesce(p_safe, true));
end;
$$;
revoke all on function public.submit_dvir(bigint, text, jsonb, numeric, text, boolean) from public, anon;
grant execute on function public.submit_dvir(bigint, text, jsonb, numeric, text, boolean) to authenticated, service_role;
