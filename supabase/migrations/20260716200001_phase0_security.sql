-- Phase 0 security + data integrity (companion prerequisites)
-- PR1: gate DEFINER RPCs + activity_log SELECT
-- PR2: tighten documents + storage SELECT/INSERT
-- PR4: numbering locks, double-booking, void paid, invoice dedupe

-- ========== PR1: dashboard_summary + global_search role gates ==========

create or replace function public.dashboard_summary()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  wk_start date := current_date - ((extract(isodow from current_date))::int - 1);
  result jsonb;
begin
  if public.my_role() not in ('admin', 'accountant', 'dispatcher') then
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
  if public.my_role() not in ('admin', 'accountant', 'dispatcher') then
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

-- activity_log: staff only (not drivers)
drop policy if exists activity_select on public.activity_log;
create policy activity_select on public.activity_log
  for select to authenticated
  using (public.my_role() in ('admin', 'dispatcher', 'accountant', 'maintenance'));

-- ========== PR2: documents + storage RLS ==========

drop policy if exists documents_select on public.documents;
drop policy if exists documents_insert on public.documents;
drop policy if exists documents_delete on public.documents;

create policy documents_select on public.documents
  for select to authenticated
  using (public.my_role() in ('admin', 'dispatcher', 'accountant'));

create policy documents_insert on public.documents
  for insert to authenticated
  with check (
    public.my_role() in ('admin', 'dispatcher')
    and uploaded_by = auth.uid()
  );

create policy documents_delete on public.documents
  for delete to authenticated
  using (public.my_role() in ('admin', 'dispatcher'));

drop policy if exists documents_bucket_read on storage.objects;
drop policy if exists documents_bucket_write on storage.objects;
drop policy if exists documents_bucket_delete on storage.objects;

create policy documents_bucket_read on storage.objects
  for select to authenticated
  using (
    bucket_id = 'documents'
    and public.my_role() in ('admin', 'dispatcher', 'accountant')
  );

create policy documents_bucket_write on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'documents'
    and public.my_role() in ('admin', 'dispatcher')
  );

create policy documents_bucket_delete on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'documents'
    and public.my_role() in ('admin', 'dispatcher')
  );

-- ========== PR4: safe numbering (advisory lock) ==========

create or replace function public.next_load_number()
returns text language plpgsql as $$
declare
  prefix text := 'LD-' || extract(year from now())::text || '-';
  seq int;
begin
  perform pg_advisory_xact_lock(hashtext('load_number:' || prefix));
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
  perform pg_advisory_xact_lock(hashtext('invoice_number:' || prefix));
  select coalesce(max(substring(invoice_number from length(prefix) + 1)::int), 0) + 1
    into seq
    from public.invoices
   where invoice_number like prefix || '%';
  return prefix || lpad(seq::text, 4, '0');
end;
$$;

-- Double-booking guard: same driver/truck cannot be on two active loads
create or replace function public.assert_no_double_booking(p_load_id bigint, p_driver_id bigint, p_truck_id bigint, p_status public.load_status)
returns void
language plpgsql
as $$
begin
  if p_status not in ('assigned', 'in_transit') then
    return;
  end if;
  if p_driver_id is not null then
    if exists (
      select 1 from public.loads
       where driver_id = p_driver_id
         and status in ('assigned', 'in_transit')
         and id is distinct from p_load_id
    ) then
      raise exception 'Driver is already assigned to another active load';
    end if;
  end if;
  if p_truck_id is not null then
    if exists (
      select 1 from public.loads
       where truck_id = p_truck_id
         and status in ('assigned', 'in_transit')
         and id is distinct from p_load_id
    ) then
      raise exception 'Truck is already assigned to another active load';
    end if;
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
    -- RPCs still must not double-book when assigning
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

-- Recompute equipment from remaining active loads (no blind available)
create or replace function public.sync_equipment_status()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  ids bigint[];
  tid bigint;
begin
  ids := array[]::bigint[];
  if tg_op = 'DELETE' then
    if old.truck_id is not null then ids := array_append(ids, old.truck_id); end if;
  else
    if new.truck_id is not null then ids := array_append(ids, new.truck_id); end if;
    if tg_op = 'UPDATE' and old.truck_id is not null and old.truck_id is distinct from new.truck_id then
      ids := array_append(ids, old.truck_id);
    end if;
  end if;

  foreach tid in array ids loop
    update public.trucks t set status = case
      when exists (
        select 1 from public.loads l
         where l.truck_id = tid and l.status in ('assigned', 'in_transit')
      ) then 'in_use'::public.equipment_status
      when t.status in ('maintenance', 'retired') then t.status
      else 'available'::public.equipment_status
    end
    where t.id = tid;
  end loop;

  ids := array[]::bigint[];
  if tg_op = 'DELETE' then
    if old.trailer_id is not null then ids := array_append(ids, old.trailer_id); end if;
  else
    if new.trailer_id is not null then ids := array_append(ids, new.trailer_id); end if;
    if tg_op = 'UPDATE' and old.trailer_id is not null and old.trailer_id is distinct from new.trailer_id then
      ids := array_append(ids, old.trailer_id);
    end if;
  end if;

  foreach tid in array ids loop
    update public.trailers t set status = case
      when exists (
        select 1 from public.loads l
         where l.trailer_id = tid and l.status in ('assigned', 'in_transit')
      ) then 'in_use'::public.equipment_status
      when t.status in ('maintenance', 'retired') then t.status
      else 'available'::public.equipment_status
    end
    where t.id = tid;
  end loop;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

-- void_invoice: refuse paid; create_invoice: dedupe load ids
create or replace function public.create_invoice(p_customer_id bigint, p_load_ids bigint[], p_due_date timestamptz default null)
returns public.invoices
language plpgsql security definer set search_path = public
as $$
declare
  inv public.invoices;
  l record;
  v_total numeric(12,2) := 0;
  load_ids bigint[];
begin
  if public.my_role() not in ('admin', 'accountant', 'dispatcher') then
    raise exception 'Not enough permissions';
  end if;

  select coalesce(array_agg(distinct x), '{}') into load_ids from unnest(p_load_ids) as x where x is not null;
  if array_length(load_ids, 1) is null then
    raise exception 'Select at least one load';
  end if;

  for l in select * from public.loads where id = any(load_ids) for update loop
    if l.customer_id <> p_customer_id then
      raise exception '% belongs to a different customer', l.load_number;
    end if;
    if l.status <> 'completed' then
      raise exception '% is not completed', l.load_number;
    end if;
    if l.invoice_id is not null then
      raise exception '% is already invoiced', l.load_number;
    end if;
    v_total := v_total + l.rate;
  end loop;

  if (select count(*) from public.loads where id = any(load_ids)) <> cardinality(load_ids) then
    raise exception 'One or more loads not found';
  end if;

  insert into public.invoices (invoice_number, customer_id, due_date, total)
  values (public.next_invoice_number(), p_customer_id, p_due_date, v_total)
  returning * into inv;

  perform set_config('app.load_rpc', '1', true);
  update public.loads set invoice_id = inv.id, status = 'billed' where id = any(load_ids);
  perform set_config('app.load_rpc', '', true);

  insert into public.activity_log (entity_type, entity_id, user_id, action, detail)
  select 'load', id, auth.uid(), 'status_changed', 'completed → billed (' || inv.invoice_number || ')'
    from public.loads where id = any(load_ids);

  return inv;
end;
$$;

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
