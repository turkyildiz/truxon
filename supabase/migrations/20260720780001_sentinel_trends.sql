-- R3 #4 -- trend anomalies become Sentinel findings. sentinel_scan
-- auto-resolves anything outside its own _findings set, so trend checks MUST
-- live inside the scan (a separate filer would be resolved on the next run).
-- Whole function reproduced from 20260720540001 with the trend block added.
create or replace function public.sentinel_scan()
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  fired int;
  resolved int;
  v_dso numeric;
begin
  if auth.role() <> 'service_role' and public.my_role() <> 'admin' then
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

  -- Missing PODs — one summary nudge (there can be 100+). Brokers won't pay
  -- without proof of delivery; call out how many already have a matching file in
  -- the PODs archive ready to attach from the load page.
  insert into _findings
  select 'missing_pods', 'cash',
         case when cnt.n >= 20 then 'critical' else 'warn' end,
         cnt.n||' delivered load'||case when cnt.n = 1 then '' else 's' end||' missing a POD',
         'Brokers won''t pay without proof of delivery'
           ||case when cnt.archived > 0
                  then ' — '||cnt.archived||' already have a matching file in the PODs archive, ready to attach'
                  else '' end,
         '', null
    from (
      select count(*)::int as n,
             count(*) filter (
               where public.pod_archive_candidate(coalesce(lm.reference_number,''),
                                                   coalesce(lm.pickup_number,''),
                                                   coalesce(lm.delivery_number,'')) is not null
             )::int as archived
        from public.loads_missing_pod(45) lm
    ) cnt
   where cnt.n > 0;

  -- Predictive slow-pay: this broker's own history says the invoice WILL land
  -- late. Early warning while a nudge can still move it. Auto-resolves on pay.
  select coalesce(round(avg(cpp.avg_days), 1), 30) into v_dso from public.customer_pay_profile() cpp;
  insert into _findings
  select 'slow_pay:'||r.invoice_id, 'cash', 'warn',
         r.customer||' will likely pay '||r.invoice_number||' late',
         '$'||round(r.outstanding, 2)||' open — '||r.customer||' averages '||round(r.avg_days)||' days to pay; predicts ~'
           ||r.predicted_days_late||' days past the '||to_char(r.due_date,'Mon DD')||' due date. Nudge now to protect cash flow.',
         'customer', r.customer_id
    from (
      select i.id as invoice_id,
             case when i.invoice_number like 'QBO-%'
                  then '#'||coalesce(nullif(i.qbo_doc_number,''), substring(i.invoice_number from 5))
                  else i.invoice_number end as invoice_number,
             c.company_name as customer, i.customer_id, i.total,
             round(case when i.source = 'qbo' and i.qbo_balance is not null then i.qbo_balance
                        else i.total - coalesce(pay.paid, 0) end, 2) as outstanding,
             coalesce(p.avg_days, v_dso) as avg_days,
             coalesce(i.due_date::date, i.invoice_date::date + 30) as due_date,
             greatest(0, (i.invoice_date::date + coalesce(p.avg_days, v_dso)::int)
                         - coalesce(i.due_date::date, i.invoice_date::date + 30))::int as predicted_days_late
        from public.invoices i
        join public.customers c on c.id = i.customer_id
        left join (select * from public.customer_pay_profile()) p on p.customer_id = i.customer_id
        left join (select p2.invoice_id, sum(p2.amount) as paid
                     from public.invoice_payments p2 group by p2.invoice_id) pay on pay.invoice_id = i.id
       where i.status = 'sent'
    ) r
   where r.predicted_days_late > 15
     and r.outstanding >= 1
     and not (r.outstanding <= 200 and r.outstanding <= 0.10 * r.total);


  -- Detention: ELD dwell says the truck sat past free time and the broker owes.
  -- Fires per stop; ages out of the 14-day window (bill it before then).
  insert into _findings
  select 'detention:'||d.load_id||':'||d.stop_type, 'cash',
         case when d.est_pay >= 300 then 'critical' else 'warn' end,
         'Detention billable — load '||d.load_number||' ('||round(d.detention_min/60.0,1)||'h over free at '||d.stop_type||')',
         'Truck sat '||round(d.dwell_min/60.0,1)||'h at the '||d.stop_type
           ||coalesce(' in '||nullif(d.stop_state,''),'')||' — ~$'||d.est_pay||' detention owed by '||d.customer
           ||'. Bill it back (confirm the broker''s rate-con terms).',
         'load', d.load_id
    from public.detention_events(14) d
   where d.est_pay >= 50;

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

  -- FMCSA safety rating lost, or authority pulled — existential, fires critical.
  insert into _findings
  select 'fmcsa_rating', 'compliance', 'critical',
         case when s.allowed_to_operate = 'N' then 'FMCSA — NOT authorized to operate'
              else 'FMCSA safety rating: '||public.fmcsa_rating_label(s.safety_rating) end,
         'As of '||to_char(s.snapshot_date,'Mon DD, YYYY')
           ||' — driver OOS '||coalesce(round(s.driver_oos_rate,1)::text,'?')||'%'
           ||', vehicle OOS '||coalesce(round(s.vehicle_oos_rate,1)::text,'?')||'%',
         '', null
    from (select * from public.carrier_safety_snapshot order by snapshot_date desc limit 1) s
   where s.allowed_to_operate = 'N' or upper(s.safety_rating) in ('C','U');

  -- ===== MAINTENANCE =====
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

  insert into _findings
  select 'wo_stale:'||m.id, 'maintenance', 'warn',
         'Work order open '||(current_date - m.created_at::date)||' days',
         coalesce(nullif(m.description,''),'(no description)')||' — unit '
           ||coalesce((select unit_number from public.trucks where id=m.truck_id),
                      (select unit_number from public.trailers where id=m.trailer_id),'?'),
         m.equipment_type::text, coalesce(m.truck_id, m.trailer_id)
    from public.maintenance_records m
   where m.status in ('scheduled','in_progress') and m.created_at < now() - interval '10 days';

  -- ===== DATA HYGIENE =====
  -- a load still "moving" a week past its delivery appointment was almost
  -- certainly delivered and never closed out (the loads #2/#11 pattern)
  insert into _findings
  select 'stale_transit:'||l.id, 'data', 'warn',
         'Load '||l.load_number||' still '||l.status||' '
           ||(current_date - coalesce(l.delivery_time, l.pickup_time)::date)||' days after its appointment',
         'Assigned '||coalesce((select d.full_name from public.drivers d where d.id = l.driver_id), 'no driver')
           ||' / '||coalesce((select t.unit_number from public.trucks t where t.id = l.truck_id), 'no truck')
           ||' — mark delivered/cancelled so dispatch, billing and forecasts see reality',
         'load', l.id
    from public.loads l
   where l.status in ('assigned', 'in_transit')
     and coalesce(l.delivery_time, l.pickup_time) < now() - interval '7 days';

  -- one driver on two active loads blocks dispatch and poisons utilization
  insert into _findings
  select 'double_booked:'||d.id, 'data', 'critical',
         d.full_name||' is on '||count(*)||' active loads at once',
         string_agg(l.load_number, ', ' order by l.id)
           ||' — resolve which is real; stale ones should be delivered/cancelled',
         'driver', d.id
    from public.loads l join public.drivers d on d.id = l.driver_id
   where l.status in ('assigned', 'in_transit')
   group by d.id, d.full_name
  having count(*) > 1;

  -- a delivered load with no POD/BOL after 14 days cannot be invoiced cleanly
  insert into _findings
  select 'missing_pod:'||l.id, 'data', 'warn',
         'Load '||l.load_number||' has no POD '
           ||(current_date - coalesce(l.delivery_time, l.updated_at)::date)||' days after delivery',
         'Customer '||coalesce((select c.company_name from public.customers c where c.id = l.customer_id), '?')
           ||' — chase the paperwork or billing stalls (the dispatch miner is also searching the inbox)',
         'load', l.id
    from public.loads l
   where l.status in ('delivered', 'completed')
     and coalesce(l.delivery_time, l.updated_at) < now() - interval '14 days'
     and coalesce(l.delivery_time, l.updated_at) > now() - interval '60 days'
     and not exists (select 1 from public.documents doc
                      where doc.entity_type = 'load' and doc.entity_id = l.id
                        and doc.doc_type in ('pod', 'bol', 'receipt', 'scale'));

  -- ===== R3 #4: trend breaks — no red metric without an action =====
  -- Any nightly-snapshotted series that lurched >=25% week-over-week gets a
  -- finding. Auto-resolve clears it once the series settles; dedup keeps one
  -- finding per series. wow_pct is null when the prior week was 0 — skip
  -- those (a series being born is not an anomaly).
  insert into _findings
  select 'trend:'||t.metric_key, 'ops', 'warn',
         'Trend break — '||t.metric_key,
         t.metric_key||' moved '||round(t.wow_pct, 1)||'% WoW (now '||round(t.latest, 1)
           ||', 13-week slope '||coalesce(round(t.slope_13w, 2)::text, '?')
           ||'). The playbook rule: no red metric without an action.',
         '', null
    from public.metric_trends(null) t
   where t.points >= 4
     and t.wow_pct is not null
     and abs(t.wow_pct) >= 25;

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
$$;
