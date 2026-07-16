-- Truxon TMS — RBAC hardening (2026-07-16 security audit).
--
-- 1. dashboard_summary / global_search were SECURITY DEFINER with only an
--    "authenticated" check, handing the driver and maintenance roles the
--    company-wide revenue, customer list, driver roster, and active-load
--    routes that table RLS deliberately denies them.
-- 2. documents, activity_log, and the storage bucket were readable (and
--    writable) by every authenticated role — a driver could download other
--    drivers' license scans or customer billing documents.
-- 3. change_load_status allowed billed → completed, unlocking a load for
--    edits while its invoice still references it. Corrections to a billed
--    load must go through void_invoice, which reverts its loads and removes
--    the invoice atomically.

-- ---------- reporting RPCs: office roles only ----------

create or replace function public.dashboard_summary()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  wk_start date := current_date - ((extract(isodow from current_date))::int - 1);
  result jsonb;
begin
  if public.my_role() not in ('admin', 'dispatcher', 'accountant') then
    raise exception 'Not enough permissions';
  end if;

  with wk_loads as (
    select * from public.loads
     where status in ('completed', 'billed')
       and delivery_time >= wk_start::timestamptz
       and delivery_time < (wk_start + 7)::timestamptz
  )
  select jsonb_build_object(
    'week_revenue', (select coalesce(sum(rate), 0) from wk_loads),
    'week_miles', (select coalesce(sum(miles), 0) from wk_loads),
    'week_loads', (select count(*)::int from wk_loads),
    'week_avg_rate_per_mile', (select case when coalesce(sum(miles), 0) > 0 then round(sum(rate) / sum(miles), 2) end from wk_loads),
    'available_trucks', (select count(*)::int from public.trucks where status = 'available'),
    'active_drivers', (select count(*)::int from public.drivers where status = 'active'),
    'status_counts', (select coalesce(jsonb_object_agg(status, n), '{}'::jsonb)
                        from (select status, count(*)::int as n from public.loads group by status) s),
    'revenue_by_day', (select jsonb_agg(jsonb_build_object(
                          'day', to_char(d.day, 'Dy'),
                          'revenue', coalesce((select sum(rate) from wk_loads w where w.delivery_time::date = d.day), 0))
                          order by d.day)
                         from generate_series(wk_start, wk_start + 6, interval '1 day') as d(day)),
    'expiring_licenses', coalesce((select jsonb_agg(to_jsonb(d)) from (
                            select id, full_name, license_expiration from public.drivers
                             where status = 'active' and license_expiration is not null
                               and license_expiration <= current_date + 30
                          ) d), '[]'::jsonb),
    'active_loads', coalesce((select jsonb_agg(to_jsonb(al) order by al.pickup_time) from (
                        select l.id, l.load_number, l.status, l.pickup_address, l.pickup_time,
                               l.delivery_address, l.delivery_time,
                               c.company_name as customer_name, d.full_name as driver_name
                          from public.loads l
                          join public.customers c on c.id = l.customer_id
                          left join public.drivers d on d.id = l.driver_id
                         where l.status in ('assigned', 'in_transit')
                         limit 25
                      ) al), '[]'::jsonb)
  ) into result;

  return result;
end;
$$;

create or replace function public.global_search(q text)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if public.my_role() not in ('admin', 'dispatcher', 'accountant') then
    raise exception 'Not enough permissions';
  end if;
  return jsonb_build_object(
    'loads', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'label', l.load_number || ' — ' || c.company_name))
                from (select * from public.loads
                       where load_number ilike '%' || q || '%'
                          or pickup_address ilike '%' || q || '%'
                          or delivery_address ilike '%' || q || '%' limit 10) l
                join public.customers c on c.id = l.customer_id), '[]'::jsonb),
    'customers', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'label', company_name))
                    from (select id, company_name from public.customers where company_name ilike '%' || q || '%' limit 10) c), '[]'::jsonb),
    'drivers', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'label', full_name))
                  from (select id, full_name from public.drivers where full_name ilike '%' || q || '%' limit 10) d), '[]'::jsonb),
    'trucks', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'label', unit_number))
                 from (select id, unit_number from public.trucks where unit_number ilike '%' || q || '%' limit 10) t), '[]'::jsonb)
  );
end;
$$;

-- ---------- change_load_status: billed loads are immutable ----------

create or replace function public.change_load_status(p_load_id bigint, p_status public.load_status)
returns public.loads
language plpgsql security definer set search_path = public
as $$
declare
  l public.loads;
  statuses public.load_status[] := array['pending','assigned','in_transit','delivered','completed','billed'];
  cur_idx int;
  new_idx int;
begin
  if public.my_role() not in ('admin', 'dispatcher', 'accountant') then
    raise exception 'Not enough permissions';
  end if;

  select * into l from public.loads where id = p_load_id for update;
  if not found then
    raise exception 'Load not found';
  end if;
  if l.status = 'billed' then
    raise exception 'Load is billed — void its invoice to make changes';
  end if;

  cur_idx := array_position(statuses, l.status);
  new_idx := array_position(statuses, p_status);

  if new_idx = cur_idx then
    return l;
  end if;
  -- Forward one step at a time; backward one step for corrections.
  if new_idx not in (cur_idx + 1, cur_idx - 1) then
    raise exception 'Cannot go from % to %', l.status, p_status;
  end if;
  if p_status = 'assigned' and (l.driver_id is null or l.truck_id is null) then
    raise exception 'Assign a driver and truck first';
  end if;
  if p_status = 'billed' and l.invoice_id is null then
    raise exception 'Generate an invoice to mark a load billed';
  end if;

  perform set_config('app.load_rpc', '1', true);
  update public.loads set status = p_status where id = p_load_id returning * into l;
  perform set_config('app.load_rpc', '', true);

  insert into public.activity_log (entity_type, entity_id, user_id, action, detail)
  values ('load', p_load_id, auth.uid(), 'status_changed', statuses[cur_idx] || ' → ' || p_status);

  return l;
end;
$$;

-- ---------- documents & activity: role-scoped access ----------
-- Office roles see everything; maintenance sees only equipment/repair
-- records; drivers (no document/notes UI) see nothing.

drop policy documents_select on public.documents;
create policy documents_select on public.documents
  for select to authenticated
  using (
    public.my_role() in ('admin', 'dispatcher', 'accountant')
    or (public.my_role() = 'maintenance' and entity_type in ('truck', 'trailer', 'maintenance'))
  );

drop policy documents_insert on public.documents;
create policy documents_insert on public.documents
  for insert to authenticated
  with check (
    uploaded_by = auth.uid()
    and (
      public.my_role() in ('admin', 'dispatcher', 'accountant')
      or (public.my_role() = 'maintenance' and entity_type in ('truck', 'trailer', 'maintenance'))
    )
  );

drop policy activity_select on public.activity_log;
create policy activity_select on public.activity_log
  for select to authenticated
  using (
    public.my_role() in ('admin', 'dispatcher', 'accountant')
    or (public.my_role() = 'maintenance' and entity_type in ('truck', 'trailer', 'maintenance'))
  );

drop policy activity_insert_notes on public.activity_log;
create policy activity_insert_notes on public.activity_log
  for insert to authenticated
  with check (
    action = 'note' and user_id = auth.uid()
    and (
      public.my_role() in ('admin', 'dispatcher', 'accountant')
      or (public.my_role() = 'maintenance' and entity_type in ('truck', 'trailer', 'maintenance'))
    )
  );

-- ---------- storage bucket: same scoping via path prefix ----------
-- Object paths are <entity_type>/<entity_id>/<uuid>_<filename>.

drop policy documents_bucket_read on storage.objects;
create policy documents_bucket_read on storage.objects
  for select to authenticated
  using (
    bucket_id = 'documents'
    and (
      public.my_role() in ('admin', 'dispatcher', 'accountant')
      or (public.my_role() = 'maintenance'
          and (name like 'truck/%' or name like 'trailer/%' or name like 'maintenance/%'))
    )
  );

drop policy documents_bucket_write on storage.objects;
create policy documents_bucket_write on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'documents'
    and (
      public.my_role() in ('admin', 'dispatcher', 'accountant')
      or (public.my_role() = 'maintenance'
          and (name like 'truck/%' or name like 'trailer/%' or name like 'maintenance/%'))
    )
  );
