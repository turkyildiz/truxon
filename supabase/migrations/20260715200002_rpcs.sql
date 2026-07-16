-- Truxon TMS — workflow RPCs and reporting functions.
-- All are SECURITY INVOKER (default): RLS on the underlying tables decides
-- who may call them, except where noted.

-- ---------- Load status workflow ----------

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

-- ---------- Invoicing ----------

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

  for l in select * from public.loads where id = any(p_load_ids) for update loop
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

  if (select count(*) from public.loads where id = any(p_load_ids)) <> cardinality(p_load_ids) then
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

-- ---------- Reporting ----------

-- Monday-through-Sunday week containing p_week_of; loads count when their
-- delivery_time falls in the week and they are completed or billed.
create or replace function public.weekly_report(p_week_of date default current_date)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  wk_start date := p_week_of - ((extract(isodow from p_week_of))::int - 1);
  wk_end date := wk_start + 6;
  result jsonb;
begin
  if public.my_role() not in ('admin', 'accountant', 'dispatcher') then
    raise exception 'Not enough permissions';
  end if;

  with wk_loads as (
    select l.*
      from public.loads l
     where l.status in ('completed', 'billed')
       and l.delivery_time >= wk_start::timestamptz
       and l.delivery_time < (wk_end + 1)::timestamptz
  ),
  by_truck as (
    select t.id as key_id, t.unit_number as name,
           count(*)::int as loads, sum(w.miles) as miles, sum(w.rate) as revenue,
           case when sum(w.miles) > 0 then round(sum(w.rate) / sum(w.miles), 2) end as avg_rate_per_mile
      from wk_loads w join public.trucks t on t.id = w.truck_id
     group by t.id, t.unit_number
  ),
  by_driver as (
    select d.id as key_id, d.full_name as name,
           count(*)::int as loads, sum(w.miles) as miles, sum(w.rate) as revenue,
           case when sum(w.miles) > 0 then round(sum(w.rate) / sum(w.miles), 2) end as avg_rate_per_mile,
           round(sum(w.miles) * d.pay_per_mile, 2) as driver_pay
      from wk_loads w join public.drivers d on d.id = w.driver_id
     group by d.id, d.full_name, d.pay_per_mile
  )
  select jsonb_build_object(
    'week_start', wk_start,
    'week_end', wk_end,
    'by_truck', coalesce((select jsonb_agg(to_jsonb(bt) order by bt.revenue desc) from by_truck bt), '[]'::jsonb),
    'by_driver', coalesce((select jsonb_agg(to_jsonb(bd) order by bd.revenue desc) from by_driver bd), '[]'::jsonb),
    'totals', (select jsonb_build_object(
        'loads', count(*)::int,
        'miles', coalesce(sum(miles), 0),
        'revenue', coalesce(sum(rate), 0),
        'avg_rate_per_mile', case when coalesce(sum(miles), 0) > 0 then round(sum(rate) / sum(miles), 2) end
      ) from wk_loads)
  ) into result;

  return result;
end;
$$;

create or replace function public.dashboard_summary()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  wk_start date := current_date - ((extract(isodow from current_date))::int - 1);
  result jsonb;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
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
  if auth.uid() is null then
    raise exception 'Not authenticated';
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

-- Set invoice status (draft → sent → paid, any direction allowed for corrections).
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
  update public.invoices set status = p_status where id = p_invoice_id returning * into inv;
  if not found then
    raise exception 'Invoice not found';
  end if;
  return inv;
end;
$$;
