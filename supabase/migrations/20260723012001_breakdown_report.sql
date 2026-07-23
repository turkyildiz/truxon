-- R9 #141: breakdown reporting from the cab. One guided tap-through instead of
-- a phone scramble: the driver says what broke, whether the truck can move, and
-- the app attaches where they are. It files an unplanned maintenance item for
-- the MX command center AND a critical ops insight so the brief/feed is loud;
-- the companion app separately rings dispatch through DND via the notify fn.
alter table public.maintenance_records drop constraint if exists maintenance_records_source_check;
alter table public.maintenance_records add constraint maintenance_records_source_check
  check (source in ('manual', 'email', 'api', 'dvir', 'breakdown'));

create or replace function public.report_breakdown(
  p_truck_id bigint,
  p_description text,
  p_drivable boolean default false,
  p_lat double precision default null,
  p_lon double precision default null
)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  d_id bigint := public.my_driver_id();
  v_unit text;
  v_name text;
  v_mx bigint;
  v_loc text := '';
begin
  if public.my_role() <> 'driver' or d_id is null then
    raise exception 'Not enough permissions' using errcode = '42501';
  end if;
  if coalesce(trim(p_description), '') = '' then
    raise exception 'Description required' using errcode = '22023';
  end if;
  select unit_number into v_unit from trucks where id = p_truck_id;
  if not found then
    raise exception 'Truck not found' using errcode = 'P0002';
  end if;
  select full_name into v_name from drivers where id = d_id;
  if p_lat is not null and p_lon is not null then
    v_loc := format(' near %s,%s', round(p_lat::numeric, 5), round(p_lon::numeric, 5));
  end if;

  insert into maintenance_records
    (equipment_type, truck_id, description, cost, is_planned, status,
     service_type, scheduled_date, source, needs_review)
  values
    ('truck', p_truck_id,
     format('BREAKDOWN — unit %s, %s%s: %s%s', v_unit, coalesce(v_name, 'driver'),
            v_loc, trim(p_description),
            case when p_drivable then ' [drivable]' else ' [NOT DRIVABLE]' end),
     0, false, 'scheduled', 'other', current_date, 'breakdown', true)
  returning id into v_mx;

  -- one insight per report; dedup on the MX row so repeat reports stay distinct
  insert into trux_insights (dedup_key, category, severity, title, detail, entity_type, entity_id)
  values ('breakdown:' || v_mx, 'ops', 'critical',
          format('Breakdown — unit %s (%s)', v_unit, coalesce(v_name, 'driver')),
          trim(p_description)
            || case when p_drivable then ' — drivable' else ' — NOT drivable' end
            || v_loc,
          'truck', p_truck_id);

  return jsonb_build_object('maintenance_id', v_mx, 'drivable', p_drivable);
end;
$$;
revoke all on function public.report_breakdown(bigint, text, boolean, double precision, double precision) from public, anon;
grant execute on function public.report_breakdown(bigint, text, boolean, double precision, double precision) to authenticated, service_role;
