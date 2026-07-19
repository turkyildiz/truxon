-- Maintenance module, phase 3 — cost analytics + playbook coverage.
--
-- Answers "where is maintenance money going, and is it planned or reactive?"
--   * maintenance_by_truck   — cost + CPM per unit (miles from the fuel-odometer
--                              delta across the window — honest, no telematics)
--   * maintenance_by_vendor  — outsourced-shop spend, grouped by vendor
--   * maintenance_cpm        — fleet Maintenance CPM & Tire CPM (playbook #29/#31)
--   * maintenance_summary    — planned vs reactive, PM compliance %, deadlined %,
--                              by-service breakdown, top cost units
-- Flips the metrics these truly compute from needs_data -> live.

-- Per-truck maintenance cost and cost-per-mile. Window miles come from the
-- fuel-card odometer progression (last reading before p_end minus last before
-- p_start); CPM is null when we can't establish miles honestly.
create or replace function public.maintenance_by_truck(p_start timestamptz, p_end timestamptz)
returns table (truck_id bigint, unit_number text, events int,
               planned_cost numeric, reactive_cost numeric, total_cost numeric,
               window_miles bigint, cpm numeric)
language sql stable security definer set search_path = public as $$
  select t.id, t.unit_number,
         count(m.id)::int,
         coalesce(sum(m.cost) filter (where m.is_planned),0),
         coalesce(sum(m.cost) filter (where not m.is_planned),0),
         coalesce(sum(m.cost),0),
         mi.window_miles,
         case when mi.window_miles > 0 then round(coalesce(sum(m.cost),0)/mi.window_miles,3) end
    from public.trucks t
    left join public.maintenance_records m
      on m.truck_id = t.id and m.status = 'completed'
     and m.date_completed >= p_start::date and m.date_completed < p_end::date
    left join lateral (
      select (
        (select coalesce(nullif(f2.telematics_odometer,0), nullif(f2.prompted_odometer,0))
           from public.fuel_transactions f2
          where f2.truck_id = t.id and f2.transaction_time < p_end
            and coalesce(nullif(f2.telematics_odometer,0), nullif(f2.prompted_odometer,0)) is not null
          order by f2.transaction_time desc limit 1)
        -
        (select coalesce(nullif(f1.telematics_odometer,0), nullif(f1.prompted_odometer,0))
           from public.fuel_transactions f1
          where f1.truck_id = t.id and f1.transaction_time < p_start
            and coalesce(nullif(f1.telematics_odometer,0), nullif(f1.prompted_odometer,0)) is not null
          order by f1.transaction_time desc limit 1)
      ) as window_miles
    ) mi on true
   where (public.my_role() in ('admin','accountant','dispatcher','maintenance') or auth.role() = 'service_role')
     and t.status <> 'retired'
   group by t.id, t.unit_number, mi.window_miles
  having count(m.id) > 0
   order by 6 desc;   -- total_cost
$$;

-- Spend by shop/vendor (falls back to the free-text shop name, then unspecified).
create or replace function public.maintenance_by_vendor(p_start timestamptz, p_end timestamptz)
returns table (vendor text, events int, total_cost numeric, planned_cost numeric)
language sql stable security definer set search_path = public as $$
  select coalesce(v.name, nullif(m.technician_shop,''), '(unspecified)') as vendor,
         count(*)::int, coalesce(sum(m.cost),0),
         coalesce(sum(m.cost) filter (where m.is_planned),0)
    from public.maintenance_records m
    left join public.maintenance_vendors v on v.id = m.vendor_id
   where (public.my_role() in ('admin','accountant','dispatcher','maintenance') or auth.role() = 'service_role')
     and m.status = 'completed'
     and m.date_completed >= p_start::date and m.date_completed < p_end::date
   group by coalesce(v.name, nullif(m.technician_shop,''), '(unspecified)')
   order by 3 desc;
$$;

-- Fleet Maintenance CPM & Tire CPM (playbook #29/#31). Fleet miles use the same
-- definition as the scorecard (completed/billed loaded+empty miles).
create or replace function public.maintenance_cpm(p_start timestamptz, p_end timestamptz)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare total_mi numeric; maint numeric; planned numeric; reactive numeric; tire numeric;
begin
  if public.my_role() not in ('admin','accountant','dispatcher','maintenance') and auth.role() <> 'service_role' then
    raise exception 'Not enough permissions';
  end if;
  select coalesce(sum(miles),0) + coalesce(sum(empty_miles),0) into total_mi
    from public.loads
   where status in ('completed','billed') and delivery_time >= p_start and delivery_time < p_end;
  select coalesce(sum(cost),0),
         coalesce(sum(cost) filter (where is_planned),0),
         coalesce(sum(cost) filter (where not is_planned),0),
         coalesce(sum(cost) filter (where service_type = 'tires'),0)
    into maint, planned, reactive, tire
    from public.maintenance_records
   where status = 'completed' and date_completed >= p_start::date and date_completed < p_end::date;
  return jsonb_build_object(
    'window', jsonb_build_object('start', p_start, 'end', p_end),
    'total_miles', total_mi,
    'maintenance_cost', round(maint,2),
    'maintenance_cpm', case when total_mi > 0 then round(maint/total_mi,3) end,
    'tire_cost', round(tire,2),
    'tire_cpm', case when total_mi > 0 then round(tire/total_mi,3) end,
    'planned_cost', round(planned,2),
    'reactive_cost', round(reactive,2),
    'planned_pct', case when maint > 0 then round(planned/maint*100,1) end
  );
end;
$$;

-- One call for the command center: spend split, PM compliance, deadlined %,
-- open work orders, by-service breakdown, top cost units.
create or replace function public.maintenance_summary(p_start timestamptz, p_end timestamptz)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  events int; total numeric; planned numeric; reactive numeric;
  in_shop int; active_trucks int; deadlined int; open_wo int;
  pm_ok int; pm_checked int; by_service jsonb; top_units jsonb;
begin
  if public.my_role() not in ('admin','accountant','dispatcher','maintenance') and auth.role() <> 'service_role' then
    raise exception 'Not enough permissions';
  end if;

  select count(*), coalesce(sum(cost),0),
         coalesce(sum(cost) filter (where is_planned),0),
         coalesce(sum(cost) filter (where not is_planned),0)
    into events, total, planned, reactive
    from public.maintenance_records
   where status = 'completed' and date_completed >= p_start::date and date_completed < p_end::date;

  select count(*) filter (where status = 'maintenance') into in_shop
    from (select status from public.trucks where status <> 'retired'
          union all select status from public.trailers where status <> 'retired') q;
  select count(*), count(*) filter (where status = 'maintenance')
    into active_trucks, deadlined from public.trucks where status <> 'retired';
  select count(*) into open_wo from public.maintenance_records
   where status in ('scheduled','in_progress');

  select count(*) filter (where due_status in ('ok','due_soon')),
         count(*) filter (where due_status in ('ok','due_soon','overdue','never_serviced'))
    into pm_ok, pm_checked from public.maintenance_due();

  select coalesce(jsonb_agg(jsonb_build_object(
           'service_type', s.service_type, 'cost', round(s.cost,2), 'events', s.events)
           order by s.cost desc), '[]'::jsonb)
    into by_service from (
      select service_type::text as service_type, sum(cost) cost, count(*) events
        from public.maintenance_records
       where status = 'completed' and date_completed >= p_start::date and date_completed < p_end::date
       group by service_type) s;

  select coalesce(jsonb_agg(jsonb_build_object(
           'unit_number', bt.unit_number, 'total_cost', round(bt.total_cost,2), 'cpm', bt.cpm)
           order by bt.total_cost desc), '[]'::jsonb)
    into top_units
    from (select * from public.maintenance_by_truck(p_start, p_end) order by total_cost desc limit 5) bt;

  return jsonb_build_object(
    'window', jsonb_build_object('start', p_start, 'end', p_end),
    'events', events,
    'total_cost', round(total,2),
    'planned_cost', round(planned,2),
    'reactive_cost', round(reactive,2),
    'planned_pct', case when total > 0 then round(planned/total*100,1) end,
    'units_in_shop', in_shop,
    'deadlined_tractor_pct', case when active_trucks > 0 then round(deadlined::numeric/active_trucks*100,1) end,
    'open_work_orders', open_wo,
    'pm_compliance_pct', case when pm_checked > 0 then round(pm_ok::numeric/pm_checked*100,1) end,
    'by_service', by_service,
    'top_units', top_units
  );
end;
$$;

revoke execute on function public.maintenance_by_truck(timestamptz, timestamptz) from public, anon;
revoke execute on function public.maintenance_by_vendor(timestamptz, timestamptz) from public, anon;
revoke execute on function public.maintenance_cpm(timestamptz, timestamptz) from public, anon;
revoke execute on function public.maintenance_summary(timestamptz, timestamptz) from public, anon;
grant execute on function public.maintenance_by_truck(timestamptz, timestamptz) to authenticated;
grant execute on function public.maintenance_by_vendor(timestamptz, timestamptz) to authenticated;
grant execute on function public.maintenance_cpm(timestamptz, timestamptz) to authenticated;
grant execute on function public.maintenance_summary(timestamptz, timestamptz) to authenticated;

-- ---------- flip the metrics we now truly compute ----------
-- Maintenance CPM appears twice in the 1,000 catalog (#29 financial, #809 fleet)
-- and Tire CPM once (#31) — all backed by maintenance_cpm.
update public.playbook_metrics
   set status = 'live', source = 'maintenance_cpm(start,end)', updated_at = now()
 where status <> 'live' and name in ('Maintenance CPM','Tire CPM');
-- PM Compliance % (#268) and Deadlined Tractors % (#239) come from maintenance_summary.
update public.playbook_metrics
   set status = 'live', source = 'maintenance_summary(start,end)', updated_at = now()
 where status <> 'live' and name in ('PM Compliance %','Deadlined Tractors %');
