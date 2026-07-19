-- Email → work-order intake, backend. A shop's work-order sheet, forwarded to
-- trux@ by a trusted staff member, becomes a DRAFT maintenance record for
-- one-tap review. The security shape that matters: inbound email can reach
-- exactly ONE bounded write — create_work_order_draft — and nothing else. It
-- only ever inserts a maintenance_records row flagged source='email',
-- needs_review=true, status='scheduled' (so unreviewed cost never leaks into the
-- CPM / P&L reports, which count only 'completed'). The owner reviews, corrects,
-- and confirms in the app, which flips it to 'completed'.

alter table public.maintenance_records
  add column if not exists source text not null default 'manual'
    check (source in ('manual','email','api')),
  add column if not exists needs_review boolean not null default false;

create index if not exists maintenance_review_idx
  on public.maintenance_records (needs_review) where needs_review;

-- The single bounded write reachable from the email door. Resolves the unit and
-- shop by name; raises 'unit_not_found:<unit>' when it can't match (the email
-- handler turns that into a helpful reply). Invalid service types degrade to
-- 'other' rather than failing. Callable by service_role (the poller) or staff.
create or replace function public.create_work_order_draft(p jsonb)
returns bigint
language plpgsql security definer set search_path = public as $$
declare
  v_unit text := nullif(trim(p->>'unit_number'), '');
  v_truck bigint; v_trailer bigint; v_equip public.equipment_type;
  v_vendor bigint; v_service public.maintenance_service_type := 'other';
  new_id bigint;
begin
  if auth.role() <> 'service_role' and public.my_role() not in ('admin','dispatcher','maintenance') then
    raise exception 'Not enough permissions';
  end if;

  if v_unit is not null then
    select id into v_truck from public.trucks where unit_number = v_unit;
    if v_truck is null then
      select id into v_trailer from public.trailers where unit_number = v_unit;
    end if;
  end if;
  if v_truck is not null then v_equip := 'truck';
  elsif v_trailer is not null then v_equip := 'trailer';
  else raise exception 'unit_not_found:%', coalesce(v_unit, '(none)');
  end if;

  begin
    v_service := coalesce(nullif(p->>'service_type', '')::public.maintenance_service_type, 'other');
  exception when others then v_service := 'other';
  end;

  select id into v_vendor from public.maintenance_vendors
   where lower(name) = lower(nullif(trim(p->>'vendor'), ''));

  insert into public.maintenance_records
    (equipment_type, truck_id, trailer_id, service_type, status, is_planned,
     date_completed, scheduled_date, odometer, vendor_id, invoice_ref,
     technician_shop, description, cost, source, needs_review)
  values
    (v_equip, v_truck, v_trailer, v_service, 'scheduled', false,
     null, nullif(p->>'date', '')::date,
     nullif(p->>'odometer', '')::bigint, v_vendor, coalesce(p->>'invoice_ref', ''),
     case when v_vendor is null then coalesce(nullif(trim(p->>'vendor'), ''), '') else '' end,
     coalesce(nullif(trim(p->>'description'), ''), 'Emailed work order'),
     coalesce(nullif(p->>'cost', '')::numeric, 0),
     'email', true)
  returning id into new_id;
  return new_id;
end;
$$;

revoke execute on function public.create_work_order_draft(jsonb) from public, anon;
grant execute on function public.create_work_order_draft(jsonb) to authenticated, service_role;
