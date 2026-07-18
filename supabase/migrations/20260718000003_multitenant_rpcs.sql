-- ============================================================================
-- MULTI-TENANT — PHASE 3: RPC TENANT FILTERS + PER-TENANT NUMBERING
-- ============================================================================
-- SECURITY DEFINER RPCs run as the table owner and BYPASS RLS, so the phase-2
-- restrictive policies do NOT protect data returned through them. This phase
-- adds an explicit `tenant_id = public.my_tenant_id()` filter inside every
-- read/aggregate RPC that would otherwise leak across tenants, and makes
-- load/invoice numbering per-tenant (the numbers are globally UNIQUE today, so
-- a second tenant would collide on INV-YYYY-0001 / LD-YYYY-0001).
--
-- SAFE with one tenant: my_tenant_id() = aida for everyone, so every added
-- filter is always true and numbering is unchanged (starts where it is).
--
-- Still TODO before tenant #2 (tracked in docs/MULTI_TENANT.md): tenant checks
-- inside the write RPCs (create_invoice, void_invoice, set_invoice_status,
-- change_load_status, ingest_vehicle_positions), and tenant stamping in the
-- admin-users edge function + handle_new_user. Those are a separate change.
--
-- Reversible: restore the prior function bodies; drop tenant_number_counters;
-- restore the global unique constraints.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. PER-TENANT NUMBERING
-- ---------------------------------------------------------------------------
-- 1a. Numbers must be unique PER TENANT, not globally, or tenant B collides
--     with tenant A. Swap the global unique for a composite (tenant_id, number).
alter table public.loads    drop constraint if exists loads_load_number_key;
alter table public.invoices drop constraint if exists invoices_invoice_number_key;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'loads_tenant_load_number_key') then
    alter table public.loads add constraint loads_tenant_load_number_key unique (tenant_id, load_number);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'invoices_tenant_invoice_number_key') then
    alter table public.invoices add constraint invoices_tenant_invoice_number_key unique (tenant_id, invoice_number);
  end if;
end $$;

-- 1b. Atomic per-tenant counter. One row per (tenant, kind, year); the upsert
--     increments under a row lock so concurrent inserts can't collide (the old
--     max()+1 had a race; a single global sequence can't restart per tenant).
create table if not exists public.tenant_number_counters (
  tenant_id bigint not null references public.tenants (id) on delete cascade,
  kind      text   not null,               -- 'load' | 'invoice'
  year      int    not null,
  value     bigint not null default 0,
  primary key (tenant_id, kind, year)
);

create or replace function public.next_tenant_number(p_kind text, p_prefix text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  tid bigint := public.my_tenant_id();
  yr  int := extract(year from now())::int;
  v   bigint;
begin
  if tid is null then
    raise exception 'next_tenant_number: caller has no tenant';
  end if;
  insert into public.tenant_number_counters (tenant_id, kind, year, value)
  values (tid, p_kind, yr, 1)
  on conflict (tenant_id, kind, year)
  do update set value = public.tenant_number_counters.value + 1
  returning value into v;
  return p_prefix || yr::text || '-' || lpad(v::text, 4, '0');
end;
$$;
revoke all on function public.next_tenant_number(text, text) from public, anon;
grant execute on function public.next_tenant_number(text, text) to authenticated;

-- Seed each existing tenant's counter from its current max so live numbering
-- continues without a gap or a repeat.
insert into public.tenant_number_counters (tenant_id, kind, year, value)
select l.tenant_id, 'load', extract(year from now())::int,
       coalesce(max(substring(l.load_number from '\d+$')::int), 0)
  from public.loads l
 where l.load_number ~ ('^LD-' || extract(year from now())::int || '-\d+$')
 group by l.tenant_id
on conflict (tenant_id, kind, year) do nothing;

insert into public.tenant_number_counters (tenant_id, kind, year, value)
select i.tenant_id, 'invoice', extract(year from now())::int,
       coalesce(max(substring(i.invoice_number from '\d+$')::int), 0)
  from public.invoices i
 where i.invoice_number ~ ('^INV-' || extract(year from now())::int || '-\d+$')
 group by i.tenant_id
on conflict (tenant_id, kind, year) do nothing;

-- 1c. Point the existing numbering functions at the per-tenant counter.
create or replace function public.next_load_number()
returns text language sql security definer set search_path = public as $$
  select public.next_tenant_number('load', 'LD-');
$$;

create or replace function public.next_invoice_number()
returns text language sql security definer set search_path = public as $$
  select public.next_tenant_number('invoice', 'INV-');
$$;

-- ---------------------------------------------------------------------------
-- 2. READ / AGGREGATE RPC TENANT FILTERS
-- ---------------------------------------------------------------------------

-- 2a. global_search — filter every entity subquery by tenant.
create or replace function public.global_search(q text)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if public.my_role() is null or public.my_role() not in ('admin', 'dispatcher', 'accountant') then
    raise exception 'Not enough permissions';
  end if;
  return jsonb_build_object(
    'loads', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'label', l.load_number || ' — ' || c.company_name))
                from (select * from public.loads
                       where tenant_id = public.my_tenant_id()
                         and (load_number ilike '%' || q || '%'
                          or reference_number ilike '%' || q || '%'
                          or pickup_address ilike '%' || q || '%'
                          or delivery_address ilike '%' || q || '%') limit 10) l
                join public.customers c on c.id = l.customer_id), '[]'::jsonb),
    'customers', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'label', company_name))
                    from (select id, company_name from public.customers
                           where tenant_id = public.my_tenant_id()
                             and company_name ilike '%' || q || '%' limit 10) c), '[]'::jsonb),
    'drivers', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'label', full_name))
                  from (select id, full_name from public.drivers
                         where tenant_id = public.my_tenant_id()
                           and full_name ilike '%' || q || '%' limit 10) d), '[]'::jsonb),
    'trucks', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'label', unit_number))
                 from (select id, unit_number from public.trucks
                        where tenant_id = public.my_tenant_id()
                          and unit_number ilike '%' || q || '%' limit 10) t), '[]'::jsonb)
  );
end;
$$;
revoke execute on function public.global_search(text) from public, anon;
grant execute on function public.global_search(text) to authenticated;

-- 2b. fleet_positions_snapshot — only this tenant's trucks.
create or replace function public.fleet_positions_snapshot()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if public.my_role() not in ('admin', 'dispatcher', 'accountant') then
    raise exception 'Not enough permissions';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'driver_id', c.driver_id,
      'driver_name', d.full_name,
      'truck_id', c.truck_id,
      'truck_unit', t.unit_number,
      'load_id', c.load_id,
      'load_number', l.load_number,
      'lat', c.lat,
      'lng', c.lng,
      'speed_mps', c.speed_mps,
      'heading_deg', c.heading_deg,
      'recorded_at', c.recorded_at
    ) order by d.full_name)
    from public.vehicle_position_current c
    join public.drivers d on d.id = c.driver_id
    left join public.trucks t on t.id = c.truck_id
    left join public.loads l on l.id = c.load_id
    where c.tenant_id = public.my_tenant_id()
  ), '[]'::jsonb);
end;
$$;
revoke all on function public.fleet_positions_snapshot() from public;
revoke execute on function public.fleet_positions_snapshot() from anon;
grant execute on function public.fleet_positions_snapshot() to authenticated;

-- 2c. weekly_report — scope the base load set to the tenant.
create or replace function public.weekly_report(p_week_of date default current_date)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  wk_start date := p_week_of - ((extract(isodow from p_week_of))::int - 1);
  wk_end date := wk_start + 6;
  result jsonb;
begin
  if public.my_role() is null or public.my_role() not in ('admin', 'accountant', 'dispatcher') then
    raise exception 'Not enough permissions';
  end if;

  with wk_loads as (
    select l.* from public.loads l
     where l.tenant_id = public.my_tenant_id()
       and l.status in ('completed', 'billed')
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
           sum(w.empty_miles) as empty_miles,
           case when sum(w.miles) > 0 then round(sum(w.rate) / sum(w.miles), 2) end as avg_rate_per_mile,
           round(sum(w.miles) * d.pay_per_mile
                 + case when d.empty_miles_paid then coalesce(sum(w.empty_miles), 0) * d.pay_per_empty_mile else 0 end,
             2) as driver_pay
      from wk_loads w join public.drivers d on d.id = w.driver_id
     group by d.id, d.full_name, d.pay_per_mile, d.pay_per_empty_mile, d.empty_miles_paid
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
revoke execute on function public.weekly_report(date) from public, anon;
grant execute on function public.weekly_report(date) to authenticated;

-- 2d. dashboard_summary — scope the base done_loads set + every direct
--     entity query (trucks, drivers, status_counts, expiring, active_loads).
create or replace function public.dashboard_summary()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  wk_start date := current_date - ((extract(isodow from current_date))::int - 1);
  result jsonb;
begin
  if public.my_role() is null or public.my_role() not in ('admin', 'dispatcher', 'accountant') then
    raise exception 'Not enough permissions';
  end if;

  with done_loads as (
    select * from public.loads
     where tenant_id = public.my_tenant_id()
       and status in ('completed', 'billed')
  ),
  wk_loads as (
    select * from done_loads
     where delivery_time >= wk_start::timestamptz
       and delivery_time < (wk_start + 7)::timestamptz
  ),
  prev_wk_loads as (
    select * from done_loads
     where delivery_time >= (wk_start - 7)::timestamptz
       and delivery_time < (current_date - 6)::timestamptz
  ),
  prev_yr_loads as (
    select * from done_loads
     where delivery_time >= (wk_start - 364)::timestamptz
       and delivery_time < (current_date - 363)::timestamptz
  )
  select jsonb_build_object(
    'week_revenue', (select coalesce(sum(rate), 0) from wk_loads),
    'week_miles', (select coalesce(sum(miles), 0) from wk_loads),
    'week_loads', (select count(*)::int from wk_loads),
    'week_avg_rate_per_mile', (select case when coalesce(sum(miles), 0) > 0 then round(sum(rate) / sum(miles), 2) end from wk_loads),
    'prev_week', (select jsonb_build_object(
        'revenue', coalesce(sum(rate), 0),
        'miles', coalesce(sum(miles), 0),
        'loads', count(*)::int,
        'avg_rate_per_mile', case when coalesce(sum(miles), 0) > 0 then round(sum(rate) / sum(miles), 2) end
      ) from prev_wk_loads),
    'prev_year_week', (select jsonb_build_object(
        'revenue', coalesce(sum(rate), 0),
        'miles', coalesce(sum(miles), 0),
        'loads', count(*)::int,
        'avg_rate_per_mile', case when coalesce(sum(miles), 0) > 0 then round(sum(rate) / sum(miles), 2) end
      ) from prev_yr_loads),
    'available_trucks', (select count(*)::int from public.trucks where tenant_id = public.my_tenant_id() and status = 'available'),
    'active_drivers', (select count(*)::int from public.drivers where tenant_id = public.my_tenant_id() and status = 'active'),
    'status_counts', (select coalesce(jsonb_object_agg(status, n), '{}'::jsonb)
                        from (select status, count(*)::int as n from public.loads
                               where tenant_id = public.my_tenant_id() group by status) s),
    'revenue_by_day', (select jsonb_agg(jsonb_build_object(
                          'day', to_char(d.day, 'Dy'),
                          'revenue', coalesce((select sum(rate) from wk_loads w where w.delivery_time::date = d.day), 0))
                          order by d.day)
                         from generate_series(wk_start, wk_start + 6, interval '1 day') as d(day)),
    'trend_weekly', (select jsonb_agg(jsonb_build_object(
                        'label', to_char(w.week, 'Mon DD'),
                        'revenue', coalesce(t.revenue, 0),
                        'miles', coalesce(t.miles, 0),
                        'empty_miles', coalesce(t.empty_miles, 0),
                        'loads', coalesce(t.loads, 0)) order by w.week)
                       from generate_series(wk_start - 77, wk_start, interval '7 days') as w(week)
                       left join (
                         select date_trunc('week', delivery_time)::date as week,
                                sum(rate) as revenue, sum(miles) as miles,
                                sum(coalesce(empty_miles, 0)) as empty_miles, count(*)::int as loads
                           from done_loads
                          where delivery_time >= (wk_start - 77)::timestamptz
                          group by 1
                       ) t on t.week = w.week::date),
    'trend_monthly', (select jsonb_agg(jsonb_build_object(
                        'label', to_char(m.month, 'Mon'),
                        'revenue', coalesce(t.revenue, 0),
                        'miles', coalesce(t.miles, 0),
                        'empty_miles', coalesce(t.empty_miles, 0),
                        'loads', coalesce(t.loads, 0)) order by m.month)
                       from generate_series(date_trunc('month', current_date) - interval '11 months',
                                            date_trunc('month', current_date), interval '1 month') as m(month)
                       left join (
                         select date_trunc('month', delivery_time)::date as month,
                                sum(rate) as revenue, sum(miles) as miles,
                                sum(coalesce(empty_miles, 0)) as empty_miles, count(*)::int as loads
                           from done_loads
                          where delivery_time >= date_trunc('month', current_date) - interval '11 months'
                          group by 1
                       ) t on t.month = m.month::date),
    'top_customers', coalesce((select jsonb_agg(to_jsonb(tc) order by tc.revenue desc) from (
                        select c.company_name as name, sum(l.rate) as revenue, count(*)::int as loads
                          from done_loads l join public.customers c on c.id = l.customer_id
                         where l.delivery_time >= (current_date - 90)::timestamptz
                         group by c.company_name
                         order by 2 desc limit 6
                      ) tc), '[]'::jsonb),
    'driver_perf', coalesce((select jsonb_agg(to_jsonb(dp) order by dp.miles desc) from (
                        select d.full_name as name, sum(l.miles) as miles,
                               sum(l.rate) as revenue, count(*)::int as loads
                          from done_loads l join public.drivers d on d.id = l.driver_id
                         where l.delivery_time >= (current_date - 30)::timestamptz
                         group by d.full_name
                         order by 2 desc limit 6
                      ) dp), '[]'::jsonb),
    'expiring_licenses', coalesce((select jsonb_agg(to_jsonb(d)) from (
                            select id, full_name, license_expiration from public.drivers
                             where tenant_id = public.my_tenant_id()
                               and status = 'active' and license_expiration is not null
                               and license_expiration <= current_date + 30
                          ) d), '[]'::jsonb),
    'active_loads', coalesce((select jsonb_agg(to_jsonb(al) order by al.pickup_time) from (
                        select l.id, l.load_number, l.status, l.pickup_address, l.pickup_time,
                               l.delivery_address, l.delivery_time,
                               c.company_name as customer_name, d.full_name as driver_name
                          from public.loads l
                          join public.customers c on c.id = l.customer_id
                          left join public.drivers d on d.id = l.driver_id
                         where l.tenant_id = public.my_tenant_id()
                           and l.status in ('assigned', 'in_transit')
                         limit 25
                      ) al), '[]'::jsonb)
  ) into result;
  return result;
end;
$$;
revoke execute on function public.dashboard_summary() from public, anon;
grant execute on function public.dashboard_summary() to authenticated;
