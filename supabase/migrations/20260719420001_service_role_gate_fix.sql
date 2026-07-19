-- Fix the service-role permission gates for the new API-key format.
--
-- The 2026-07-19 key rotation means a raw service client's role claim no longer
-- resolves to 'service_role' (RLS-bypass via the DB role still works, but
-- auth.role() does not report it). Every RPC gated on auth.role()='service_role'
-- therefore fails when called by a pure service client (e.g. the fuel/toll
-- import crons). The robust, key-format-agnostic signal for "no end-user is
-- logged in" is auth.uid() IS NULL — so:
--   auth.role() <> 'service_role'  ->  auth.uid() is not null
--   auth.role()  = 'service_role'  ->  auth.uid() is null
-- Definitions below are the CURRENT ones (pg_get_functiondef) with only that
-- substitution applied; grants are preserved by CREATE OR REPLACE.

CREATE OR REPLACE FUNCTION public.import_fuel_transactions(p_rows jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  before_count int;
  after_count int;
  affected int;
begin
  -- Callable by the service role (edge function) or an admin doing a manual load.
  if auth.uid() is not null and public.my_role() <> 'admin' then
    raise exception 'Not enough permissions';
  end if;
  if jsonb_typeof(p_rows) is distinct from 'array' then
    raise exception 'p_rows must be a JSON array';
  end if;

  select count(*) into before_count from public.fuel_transactions;

  with incoming as (
    select * from jsonb_to_recordset(p_rows) as x(
      uuid text, transaction_time timestamptz, posted_date timestamptz, status text,
      card_last_four text, merchant text, merchant_city text, merchant_state text,
      merchant_zip text, merchant_category text, amount numeric, net_of_discount numeric,
      discount numeric, fuel_type text, gallons numeric, price_per_gallon numeric,
      description text, prompted_odometer bigint, telematics_odometer bigint,
      tag text, driver_name text, vehicle_name text, vin text, raw jsonb
    )
  ),
  resolved as (
    select i.*,
      -- Match a truck by VIN when present, else by unit number = Vehicle Name.
      coalesce(
        (select t.id from public.trucks t where t.vin <> '' and t.vin = i.vin),
        (select t.id from public.trucks t where t.unit_number = i.vehicle_name)
      ) as truck_id,
      (select d.id from public.drivers d where d.full_name = i.driver_name) as driver_id
    from incoming i
  )
  insert into public.fuel_transactions (
    uuid, transaction_time, posted_date, status, card_last_four, merchant,
    merchant_city, merchant_state, merchant_zip, merchant_category, amount,
    net_of_discount, discount, fuel_type, gallons, price_per_gallon, description,
    prompted_odometer, telematics_odometer, tag, driver_name, vehicle_name, vin,
    truck_id, driver_id, raw, updated_at
  )
  select
    uuid, transaction_time, posted_date, coalesce(status,''), card_last_four, coalesce(merchant,''),
    coalesce(merchant_city,''), coalesce(merchant_state,''), coalesce(merchant_zip,''), coalesce(merchant_category,''),
    coalesce(amount,0), net_of_discount, discount, coalesce(fuel_type,''), gallons, price_per_gallon, coalesce(description,''),
    prompted_odometer, telematics_odometer, coalesce(tag,''), coalesce(driver_name,''), coalesce(vehicle_name,''), coalesce(vin,''),
    truck_id, driver_id, coalesce(raw,'{}'::jsonb), now()
  from resolved
  on conflict (uuid) do update set
    transaction_time = excluded.transaction_time,
    posted_date = excluded.posted_date,
    status = excluded.status,
    amount = excluded.amount,
    net_of_discount = excluded.net_of_discount,
    discount = excluded.discount,
    fuel_type = excluded.fuel_type,
    gallons = excluded.gallons,
    price_per_gallon = excluded.price_per_gallon,
    description = excluded.description,
    prompted_odometer = excluded.prompted_odometer,
    telematics_odometer = excluded.telematics_odometer,
    tag = excluded.tag,
    driver_name = excluded.driver_name,
    vehicle_name = excluded.vehicle_name,
    vin = excluded.vin,
    truck_id = excluded.truck_id,
    driver_id = excluded.driver_id,
    raw = excluded.raw,
    updated_at = now();

  get diagnostics affected = row_count;
  select count(*) into after_count from public.fuel_transactions;

  return jsonb_build_object(
    'received', jsonb_array_length(p_rows),
    'inserted', after_count - before_count,
    'updated', affected - (after_count - before_count),
    'unmatched_trucks', (select count(*) from public.fuel_transactions where truck_id is null)
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.import_toll_transactions(p_rows jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  before_count int;
  after_count int;
  affected int;
begin
  if auth.uid() is not null and public.my_role() <> 'admin' then
    raise exception 'Not enough permissions';
  end if;
  if jsonb_typeof(p_rows) is distinct from 'array' then
    raise exception 'p_rows must be a JSON array';
  end if;

  select count(*) into before_count from public.toll_transactions;

  with incoming as (
    select * from jsonb_to_recordset(p_rows) as x(
      toll_id text, account_number bigint, account_name text, bill_to_account_number bigint,
      bill_to_account_name text, post_date_time timestamptz, invoice_date_time timestamptz,
      exit_date_time timestamptz, entry_date_time timestamptz, device_number text,
      vehicle_number text, plate_number text, toll_agency_name text, toll_agency_state text,
      billing_agency_code text, entry_plaza_code text, entry_plaza_name text, exit_plaza_code text,
      exit_plaza_name text, read_type text, toll_class text, toll_charge numeric,
      toll_category text, dispute_status text, raw jsonb
    )
  ),
  resolved as (
    select i.*,
      (select t.id from public.trucks t where t.unit_number = i.vehicle_number) as truck_id
    from incoming i
  )
  insert into public.toll_transactions (
    toll_id, account_number, account_name, bill_to_account_number, bill_to_account_name,
    post_date_time, invoice_date_time, exit_date_time, entry_date_time, device_number,
    vehicle_number, plate_number, toll_agency_name, toll_agency_state, billing_agency_code,
    entry_plaza_code, entry_plaza_name, exit_plaza_code, exit_plaza_name, read_type,
    toll_class, toll_charge, toll_category, dispute_status, truck_id, raw, updated_at
  )
  select
    toll_id, account_number, coalesce(account_name,''), bill_to_account_number, coalesce(bill_to_account_name,''),
    post_date_time, invoice_date_time, exit_date_time, entry_date_time, coalesce(device_number,''),
    coalesce(vehicle_number,''), coalesce(plate_number,''), coalesce(toll_agency_name,''), coalesce(toll_agency_state,''), coalesce(billing_agency_code,''),
    coalesce(entry_plaza_code,''), coalesce(entry_plaza_name,''), coalesce(exit_plaza_code,''), coalesce(exit_plaza_name,''), coalesce(read_type,''),
    coalesce(toll_class,''), coalesce(toll_charge,0), coalesce(toll_category,''), coalesce(dispute_status,''), truck_id, coalesce(raw,'{}'::jsonb), now()
  from resolved
  on conflict (toll_id) do update set
    account_number = excluded.account_number, account_name = excluded.account_name,
    bill_to_account_number = excluded.bill_to_account_number, bill_to_account_name = excluded.bill_to_account_name,
    post_date_time = excluded.post_date_time, invoice_date_time = excluded.invoice_date_time,
    exit_date_time = excluded.exit_date_time, entry_date_time = excluded.entry_date_time,
    device_number = excluded.device_number, vehicle_number = excluded.vehicle_number,
    plate_number = excluded.plate_number, toll_agency_name = excluded.toll_agency_name,
    toll_agency_state = excluded.toll_agency_state, billing_agency_code = excluded.billing_agency_code,
    entry_plaza_code = excluded.entry_plaza_code, entry_plaza_name = excluded.entry_plaza_name,
    exit_plaza_code = excluded.exit_plaza_code, exit_plaza_name = excluded.exit_plaza_name,
    read_type = excluded.read_type, toll_class = excluded.toll_class, toll_charge = excluded.toll_charge,
    toll_category = excluded.toll_category, dispute_status = excluded.dispute_status,
    truck_id = excluded.truck_id, raw = excluded.raw, updated_at = now();

  get diagnostics affected = row_count;
  select count(*) into after_count from public.toll_transactions;

  return jsonb_build_object(
    'received', jsonb_array_length(p_rows),
    'inserted', after_count - before_count,
    'updated', affected - (after_count - before_count),
    'unmatched_trucks', (select count(*) from public.toll_transactions where truck_id is null),
    'violations', (select count(*) from public.toll_transactions where toll_category = 'Violation')
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.create_work_order_draft(p jsonb)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_unit text := nullif(trim(p->>'unit_number'), '');
  v_truck bigint; v_trailer bigint; v_equip public.equipment_type;
  v_vendor bigint; v_service public.maintenance_service_type := 'other';
  new_id bigint;
begin
  if auth.uid() is not null and public.my_role() not in ('admin','dispatcher','maintenance') then
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
$function$
;

CREATE OR REPLACE FUNCTION public.sentinel_scan()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  fired int;
  resolved int;
begin
  if auth.uid() is not null and public.my_role() <> 'admin' then
    raise exception 'Not enough permissions';
  end if;

  drop table if exists _findings;
  create temp table _findings (
    dedup_key text primary key, category text, severity text, title text,
    detail text, entity_type text, entity_id bigint
  ) on commit drop;

  -- ===== MONEY =====
  insert into _findings
  select 'toll_violation:'||t.id, 'money',
         case when t.toll_charge >= 50 then 'critical' else 'warn' end,
         'Toll violation — '||coalesce(nullif(t.toll_agency_name,''),'unknown agency'),
         'Violation toll $'||t.toll_charge||' on unit '||coalesce(nullif(t.vehicle_number,''),'?')
           ||coalesce(' ('||nullif(t.toll_agency_state,'')||')',''),
         'truck', t.truck_id
    from public.toll_transactions t
   where t.toll_category = 'Violation' and coalesce(t.post_date_time, t.exit_date_time) > now() - interval '7 days';

  insert into _findings
  select 'unprofitable_truck:'||bt.key_id, 'money', 'warn',
         'Truck '||bt.name||' is running at a loss this week',
         'Revenue $'||bt.revenue||' vs fuel $'||bt.fuel_cost||' — net after fuel $'||bt.net_after_fuel,
         'truck', bt.key_id
    from jsonb_to_recordset(public.weekly_report()->'by_truck')
      as bt(key_id bigint, name text, revenue numeric, fuel_cost numeric, net_after_fuel numeric)
   where bt.net_after_fuel < 0;

  -- Customer concentration: a single customer > 20% of trailing-90-day revenue
  -- (playbook flags >15% as a risk to watch).
  insert into _findings
  select 'concentration:'||c.customer_id, 'money',
         case when c.share >= 35 then 'critical' else 'warn' end,
         cu.company_name||' is '||c.share||'% of revenue',
         'Customer concentration risk — '||c.share||'% of the last 90 days'' revenue rides on one account',
         'customer', c.customer_id
    from (
      select l.customer_id,
             round(sum(l.rate) / nullif((select sum(rate) from public.loads
                where status in ('completed','billed') and delivery_time > now() - interval '90 days'),0) * 100, 1) as share
        from public.loads l
       where l.status in ('completed','billed') and l.delivery_time > now() - interval '90 days'
       group by l.customer_id
    ) c join public.customers cu on cu.id = c.customer_id
   where c.share >= 20;

  -- ===== CASH =====
  insert into _findings
  select 'ar_overdue:'||a.customer_id, 'cash',
         case when a.d90_plus > 0 then 'critical' else 'warn' end,
         a.company_name||' is overdue',
         '$'||(a.d61_90 + a.d90_plus)||' past 60 days'||coalesce(' ($'||nullif(a.d90_plus,0)||' past 90)',''),
         'customer', a.customer_id
    from public.ar_aging() a where (a.d61_90 + a.d90_plus) > 0;

  insert into _findings
  select 'uninvoiced:'||l.id, 'cash', 'warn',
         'Load '||l.load_number||' delivered but not invoiced',
         'Completed '||to_char(l.delivery_time,'Mon DD')||', $'||l.rate||' not yet on an invoice',
         'load', l.id
    from public.loads l
   where l.status = 'completed' and l.invoice_id is null and l.delivery_time < now() - interval '7 days';

  -- ===== OPS =====
  insert into _findings
  select 'late_load:'||l.id, 'ops',
         case when l.delivery_time < now() - interval '12 hours' then 'critical' else 'warn' end,
         'Load '||l.load_number||' is late',
         'Delivery was due '||to_char(l.delivery_time,'Mon DD HH24:MI')||' — still '||l.status,
         'load', l.id
    from public.loads l
   where l.status in ('assigned','in_transit') and l.delivery_time < now();

  insert into _findings
  select 'gps_stale:'||dd.driver_id, 'ops', 'warn',
         'No GPS from '||d.full_name,
         'On duty since '||to_char(dd.on_duty_since,'HH24:MI')||' but no position in 30+ min',
         'driver', dd.driver_id
    from public.driver_duty dd join public.drivers d on d.id = dd.driver_id
   where dd.is_on_duty
     and not exists (select 1 from public.vehicle_position_current v
                      where v.driver_id = dd.driver_id and v.recorded_at > now() - interval '30 minutes');

  -- ===== COMPLIANCE =====
  insert into _findings
  select 'license_exp:'||d.id, 'compliance',
         case when d.license_expiration < now()::date then 'critical' else 'warn' end,
         'License '||case when d.license_expiration < now()::date then 'EXPIRED' else 'expiring' end||' — '||d.full_name,
         'CDL expires '||to_char(d.license_expiration,'Mon DD, YYYY'),
         'driver', d.id
    from public.drivers d
   where d.status = 'active' and d.license_expiration is not null and d.license_expiration < now()::date + 30;

  insert into _findings
  select 'plate_exp:'||t.id, 'compliance',
         case when t.plate_expiry < now()::date then 'critical' else 'warn' end,
         'Registration '||case when t.plate_expiry < now()::date then 'EXPIRED' else 'expiring' end||' — truck '||t.unit_number,
         'Plate '||coalesce(nullif(t.plate_number,''),'?')||' expires '||to_char(t.plate_expiry,'Mon DD, YYYY'),
         'truck', t.id
    from public.trucks t
   where t.status <> 'retired' and t.plate_expiry is not null and t.plate_expiry < now()::date + 30;

  -- Trailer registration parity with trucks.
  insert into _findings
  select 'trailer_plate_exp:'||t.id, 'compliance',
         case when t.plate_expiry < now()::date then 'critical' else 'warn' end,
         'Registration '||case when t.plate_expiry < now()::date then 'EXPIRED' else 'expiring' end||' — trailer '||t.unit_number,
         'Plate '||coalesce(nullif(t.plate_number,''),'?')||' expires '||to_char(t.plate_expiry,'Mon DD, YYYY'),
         'trailer', t.id
    from public.trailers t
   where t.status <> 'retired' and t.plate_expiry is not null and t.plate_expiry < now()::date + 30;

  -- ===== SAFETY =====
  insert into _findings
  select 'accident:'||e.id, 'compliance',
         case when e.severity = 'critical' or e.preventable then 'critical' else 'warn' end,
         'Accident logged'||case when e.preventable then ' (PREVENTABLE)' else '' end
           ||coalesce(' — '||nullif((select full_name from public.drivers where id=e.driver_id),''),''),
         to_char(e.event_date,'Mon DD')||coalesce(' at '||nullif(e.location,''),'')||coalesce(' — '||nullif(e.description,''),''),
         'driver', e.driver_id
    from public.safety_events e
   where e.event_type = 'accident' and e.event_date > now()::date - 30;

  insert into _findings
  select 'oos:'||e.id, 'compliance', 'warn',
         'Out-of-service event',
         to_char(e.event_date,'Mon DD')||coalesce(' — '||nullif(e.description,''),'')
           ||coalesce(' (unit '||nullif((select unit_number from public.trucks where id=e.truck_id),'')||')',''),
         'truck', e.truck_id
    from public.safety_events e
   where e.out_of_service and e.event_date > now()::date - 30;

  insert into _findings
  select 'safety_open_critical:'||e.id, 'compliance', 'critical',
         'Open critical '||e.event_type,
         coalesce(nullif(e.description,''),initcap(e.event_type))||
           case when e.claim_amount > 0 then ' — $'||e.claim_amount||' exposure' else '' end,
         'driver', e.driver_id
    from public.safety_events e
   where e.severity = 'critical' and e.status = 'open';

  insert into _findings
  select 'csa_alert:'||s.basic, 'compliance', 'warn',
         'CSA alert — '||replace(initcap(replace(s.basic,'_',' ')),' ',' '),
         'BASIC '||s.basic||' at '||coalesce(s.percentile::text,'?')||' percentile (over threshold)',
         '', null
    from public.safety_csa s where s.alert;

  -- ===== MAINTENANCE (newly instrumented) =====
  -- Overdue PM / inspection, per unit per program (from the due engine). Only
  -- genuinely-overdue items fire — a never-serviced unit surfaces in the in-app
  -- "Needs Attention" panel but is not pushed, to avoid flooding on a fresh
  -- fleet before any service history exists.
  insert into _findings
  select 'pm_overdue:'||d.equipment_type||':'||d.unit_id||':'||d.program_id, 'maintenance',
         case when d.service_type = 'dot_inspection' then 'critical' else 'warn' end,
         d.program_name||' overdue — '||d.unit_number,
         case when d.miles_remaining is not null and d.miles_remaining < 0 then 'Over by '||abs(d.miles_remaining)||' mi'
              when d.days_remaining  is not null and d.days_remaining  < 0 then 'Over by '||abs(d.days_remaining)||' days'
              else 'Due now' end,
         d.equipment_type, d.unit_id
    from public.maintenance_due() d
   where d.due_status = 'overdue';

  -- Repeat-breakdown units: 3+ unplanned (reactive) repairs in 30 days — a
  -- behavioural money-pit signal, no arbitrary dollar threshold.
  insert into _findings
  select 'repeat_repair:'||m.truck_id, 'maintenance', 'warn',
         'Unit '||t.unit_number||' — '||count(*)||' unplanned repairs in 30 days',
         'Repeat breakdowns totalling $'||round(sum(m.cost),2)||' reactive spend — investigate root cause',
         'truck', m.truck_id
    from public.maintenance_records m join public.trucks t on t.id = m.truck_id
   where m.status = 'completed' and not m.is_planned and m.truck_id is not null
     and m.date_completed > current_date - 30
   group by m.truck_id, t.unit_number
  having count(*) >= 3;

  -- Work orders left open too long (scheduled / in progress > 10 days).
  insert into _findings
  select 'wo_stale:'||m.id, 'maintenance', 'warn',
         'Work order open '||(current_date - m.created_at::date)||' days',
         coalesce(nullif(m.description,''),'(no description)')||' — unit '
           ||coalesce((select unit_number from public.trucks where id=m.truck_id),
                      (select unit_number from public.trailers where id=m.trailer_id),'?'),
         m.equipment_type::text, coalesce(m.truck_id, m.trailer_id)
    from public.maintenance_records m
   where m.status in ('scheduled','in_progress') and m.created_at < now() - interval '10 days';

  -- ===== upsert + auto-resolve =====
  insert into public.trux_insights (dedup_key, category, severity, title, detail, entity_type, entity_id)
  select dedup_key, category, severity, title, detail, entity_type, entity_id from _findings
  on conflict (dedup_key) do update set
    severity = excluded.severity, title = excluded.title, detail = excluded.detail, last_seen = now(),
    status = case when public.trux_insights.status = 'resolved' then 'open' else public.trux_insights.status end,
    resolved_at = case when public.trux_insights.status = 'resolved' then null else public.trux_insights.resolved_at end;
  get diagnostics fired = row_count;

  update public.trux_insights set status = 'resolved', resolved_at = now()
   where status <> 'resolved' and dedup_key not in (select dedup_key from _findings);
  get diagnostics resolved = row_count;

  return jsonb_build_object(
    'fired', fired, 'resolved', resolved,
    'open', (select count(*) from public.trux_insights where status <> 'resolved'),
    'critical', (select count(*) from public.trux_insights where status <> 'resolved' and severity = 'critical'));
end;
$function$
;

CREATE OR REPLACE FUNCTION public.sentinel_take_alerts()
 RETURNS SETOF trux_insights
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if auth.uid() is not null and public.my_role() <> 'admin' then
    raise exception 'Not enough permissions';
  end if;
  return query
  update public.trux_insights
     set notified_at = now()
   where status = 'open' and severity = 'critical' and notified_at is null
  returning *;
end; $function$
;

CREATE OR REPLACE FUNCTION public.sentinel_open_summary()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare open_n int; crit_n int; warn_n int; by_cat jsonb; top jsonb;
begin
  if auth.uid() is not null and public.my_role() not in ('admin','accountant','dispatcher') then
    raise exception 'Not enough permissions';
  end if;
  select count(*), count(*) filter (where severity='critical'), count(*) filter (where severity='warn')
    into open_n, crit_n, warn_n from public.trux_insights where status <> 'resolved';
  select coalesce(jsonb_object_agg(category, c), '{}'::jsonb) into by_cat
    from (select category, count(*) c from public.trux_insights where status <> 'resolved' group by category) x;
  select coalesce(jsonb_agg(jsonb_build_object('severity', severity, 'title', title, 'detail', detail)), '[]'::jsonb) into top
    from (select severity, title, detail from public.trux_insights where status <> 'resolved'
           order by case severity when 'critical' then 0 when 'warn' then 1 else 2 end, last_seen desc limit 8) t;
  return jsonb_build_object('open', open_n, 'critical', crit_n, 'warn', warn_n, 'by_category', by_cat, 'top', top);
end; $function$
;

CREATE OR REPLACE FUNCTION public.current_odometer(p_truck_id bigint)
 RETURNS bigint
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select reading from (
    select coalesce(nullif(f.telematics_odometer,0), nullif(f.prompted_odometer,0)) as reading,
           f.transaction_time
      from public.fuel_transactions f
     where f.truck_id = p_truck_id
       and (public.my_role() in ('admin','accountant','dispatcher','maintenance') or auth.uid() is null)
       and coalesce(nullif(f.telematics_odometer,0), nullif(f.prompted_odometer,0)) is not null
     order by f.transaction_time desc
     limit 1
  ) x;
$function$
;

CREATE OR REPLACE FUNCTION public.fleet_odometers()
 RETURNS TABLE(truck_id bigint, unit_number text, odometer bigint, reading_date timestamp with time zone)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select t.id, t.unit_number, r.reading, r.transaction_time
    from public.trucks t
    left join lateral (
      select coalesce(nullif(f.telematics_odometer,0), nullif(f.prompted_odometer,0)) as reading,
             f.transaction_time
        from public.fuel_transactions f
       where f.truck_id = t.id
         and coalesce(nullif(f.telematics_odometer,0), nullif(f.prompted_odometer,0)) is not null
       order by f.transaction_time desc
       limit 1
    ) r on true
   where (public.my_role() in ('admin','accountant','dispatcher','maintenance') or auth.uid() is null)
     and t.status <> 'retired'
   order by t.unit_number;
$function$
;

CREATE OR REPLACE FUNCTION public.maintenance_due()
 RETURNS TABLE(equipment_type text, unit_id bigint, unit_number text, program_id bigint, program_name text, service_type text, interval_miles integer, interval_days integer, last_service_date date, last_service_odometer bigint, current_odometer bigint, miles_since bigint, days_since integer, miles_remaining bigint, days_remaining integer, due_status text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
   where public.my_role() in ('admin','dispatcher','accountant','maintenance') or auth.uid() is null
   order by pr.unit_number, pr.pname;
$function$
;

CREATE OR REPLACE FUNCTION public.maintenance_alerts()
 RETURNS TABLE(kind text, severity text, equipment_type text, unit_id bigint, unit_number text, label text, detail text, due_date date, category text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
     where (public.my_role() in ('admin','dispatcher','accountant','maintenance') or auth.uid() is null)
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
     where (public.my_role() in ('admin','dispatcher','accountant','maintenance') or auth.uid() is null)
       and m.status in ('scheduled','in_progress')
       and m.created_at < now() - interval '7 days'
  ) al
  order by case al.severity when 'overdue' then 0 when 'due_soon' then 1 else 2 end, al.unit_number;
$function$
;

CREATE OR REPLACE FUNCTION public.maintenance_by_truck(p_start timestamp with time zone, p_end timestamp with time zone)
 RETURNS TABLE(truck_id bigint, unit_number text, events integer, planned_cost numeric, reactive_cost numeric, total_cost numeric, window_miles bigint, cpm numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
   where (public.my_role() in ('admin','accountant','dispatcher','maintenance') or auth.uid() is null)
     and t.status <> 'retired'
   group by t.id, t.unit_number, mi.window_miles
  having count(m.id) > 0
   order by 6 desc;   -- total_cost
$function$
;

CREATE OR REPLACE FUNCTION public.maintenance_by_vendor(p_start timestamp with time zone, p_end timestamp with time zone)
 RETURNS TABLE(vendor text, events integer, total_cost numeric, planned_cost numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce(v.name, nullif(m.technician_shop,''), '(unspecified)') as vendor,
         count(*)::int, coalesce(sum(m.cost),0),
         coalesce(sum(m.cost) filter (where m.is_planned),0)
    from public.maintenance_records m
    left join public.maintenance_vendors v on v.id = m.vendor_id
   where (public.my_role() in ('admin','accountant','dispatcher','maintenance') or auth.uid() is null)
     and m.status = 'completed'
     and m.date_completed >= p_start::date and m.date_completed < p_end::date
   group by coalesce(v.name, nullif(m.technician_shop,''), '(unspecified)')
   order by 3 desc;
$function$
;

CREATE OR REPLACE FUNCTION public.maintenance_cpm(p_start timestamp with time zone, p_end timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare total_mi numeric; maint numeric; planned numeric; reactive numeric; tire numeric;
begin
  if public.my_role() not in ('admin','accountant','dispatcher','maintenance') and auth.uid() is not null then
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
$function$
;

CREATE OR REPLACE FUNCTION public.maintenance_summary(p_start timestamp with time zone, p_end timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  events int; total numeric; planned numeric; reactive numeric;
  in_shop int; active_trucks int; deadlined int; open_wo int;
  pm_ok int; pm_checked int; by_service jsonb; top_units jsonb;
begin
  if public.my_role() not in ('admin','accountant','dispatcher','maintenance') and auth.uid() is not null then
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
$function$
;

