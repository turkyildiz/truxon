-- ============================================================================
-- MULTI-TENANT — PHASE 4: WRITE-RPC TENANT OWNERSHIP CHECKS
-- ============================================================================
-- These SECURITY DEFINER write RPCs act on a row by id and BYPASS RLS, so a
-- caller could pass a FOREIGN tenant's id. Each id lookup now ANDs
-- `tenant_id = public.my_tenant_id()`, so a foreign id resolves to "not found"
-- instead of mutating another tenant's data. Bodies are otherwise byte-for-byte
-- unchanged from their latest definitions.
--
-- ingest_vehicle_positions is intentionally NOT here: it only ever writes the
-- caller's OWN driver (my_driver_id()), auto-stamped with their tenant, so it
-- cannot cross tenants.
--
-- SAFE with one tenant: my_tenant_id() = aida for everyone, so the added
-- predicate is always true. Reversible: restore the prior bodies.
-- ============================================================================

-- create_invoice — only invoice THIS tenant's loads.
create or replace function public.create_invoice(p_customer_id bigint, p_load_ids bigint[], p_due_date timestamptz default null)
returns public.invoices
language plpgsql security definer set search_path = public
as $$
declare
  inv public.invoices;
  l record;
  v_total numeric(12,2) := 0;
begin
  if public.my_role() not in ('admin', 'accountant', 'dispatcher') then
    raise exception 'Not enough permissions';
  end if;
  if array_length(p_load_ids, 1) is null then
    raise exception 'Select at least one load';
  end if;

  for l in select * from public.loads
            where id = any(p_load_ids) and tenant_id = public.my_tenant_id() for update loop
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

  if (select count(*) from public.loads
       where id = any(p_load_ids) and tenant_id = public.my_tenant_id()) <> cardinality(p_load_ids) then
    raise exception 'One or more loads not found';
  end if;

  insert into public.invoices (invoice_number, customer_id, due_date, total)
  values (public.next_invoice_number(), p_customer_id, p_due_date, v_total)
  returning * into inv;

  perform set_config('app.load_rpc', '1', true);
  update public.loads set invoice_id = inv.id, status = 'billed' where id = any(p_load_ids);
  perform set_config('app.load_rpc', '', true);

  insert into public.activity_log (entity_type, entity_id, user_id, action, detail)
  select 'load', id, auth.uid(), 'status_changed', 'completed → billed (' || inv.invoice_number || ')'
    from public.loads where id = any(p_load_ids);

  return inv;
end;
$$;

-- void_invoice — only void THIS tenant's invoice.
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
  select * into inv from public.invoices where id = p_invoice_id and tenant_id = public.my_tenant_id() for update;
  if not found then
    raise exception 'Invoice not found';
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

-- set_invoice_status — only THIS tenant's invoice.
create or replace function public.set_invoice_status(p_invoice_id bigint, p_status public.invoice_status)
returns public.invoices
language plpgsql security definer set search_path = public
as $$
declare
  inv public.invoices;
begin
  if public.my_role() not in ('admin', 'accountant', 'dispatcher') then
    raise exception 'Not enough permissions';
  end if;
  update public.invoices set status = p_status
   where id = p_invoice_id and tenant_id = public.my_tenant_id() returning * into inv;
  if not found then
    raise exception 'Invoice not found';
  end if;
  return inv;
end;
$$;

-- change_load_status — only THIS tenant's load.
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

  select * into l from public.loads where id = p_load_id and tenant_id = public.my_tenant_id() for update;
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
