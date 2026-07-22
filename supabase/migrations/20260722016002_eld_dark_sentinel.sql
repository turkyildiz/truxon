-- R8 Block 12b - dark-ELD sentinel. Full sentinel_scan redefinition
-- (latest = 20260722014002 + spliced eld_dark check). Found live: unit 05's
-- ELD last reported 2026-01-10 - six months dark, nothing noticed. A dark ELD
-- is an HOS-compliance risk AND silently blinds MPG/idle/detention/IFTA/PM.
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
       where i.status = 'sent' and i.factored_at is null
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


  -- ===== FUEL THEFT / CARD MISUSE (added 2026-07-21) =====
  -- 1) Product mismatch: gasoline/ethanol bought on a DIESEL truck's card. A
  -- diesel truck physically can't burn these — it's a second vehicle or resale.
  insert into _findings
  select 'fuel_product:'||f.truck_id, 'money', 'critical',
         'Non-diesel fuel on truck '||coalesce(t.unit_number,'?')||' — card misuse?',
         count(*)||' non-diesel fill(s) in 30d ($'||round(sum(f.amount))::text||'): '
           ||string_agg(distinct f.fuel_type, ', ')||'. A diesel truck can''t use these.',
         'truck', f.truck_id
    from public.fuel_transactions f
    join public.trucks t on t.id = f.truck_id
   where lower(coalesce(f.fuel_type,'')) ~ '(unleaded|ethanol|gasoline|premium|regular|e85|midgrade)'
     and coalesce(f.gallons,0) > 3
     and f.transaction_time > now() - interval '30 days'
   group by f.truck_id, t.unit_number;

  -- 2) Cash advances / non-fuel charges (0-gallon spend). Fuel cards aren't ATMs.
  insert into _findings
  select 'fuel_cash:'||x.truck_id, 'money',
         case when x.nonfuel >= 2000 then 'critical' else 'warn' end,
         'High non-fuel spend on truck '||coalesce(t.unit_number,'?')||'''s fuel card',
         '$'||round(x.nonfuel)::text||' in '||x.n||' cash-advance/fee charge(s) (0 gal) in 30d'
           ||case when x.nonfuel > x.diesel then ' — MORE than its $'||round(x.diesel)::text||' of actual diesel' else '' end,
         'truck', x.truck_id
    from (
      select f.truck_id,
             coalesce(sum(f.amount) filter (where coalesce(f.gallons,0)=0 and f.amount>0),0) as nonfuel,
             count(*)              filter (where coalesce(f.gallons,0)=0 and f.amount>0)     as n,
             coalesce(sum(f.amount) filter (where coalesce(f.gallons,0)>0),0)                as diesel
        from public.fuel_transactions f
       where f.transaction_time > now() - interval '30 days'
       group by f.truck_id
    ) x
    join public.trucks t on t.id = x.truck_id
   where x.nonfuel >= 500;

  -- 3) Tank overflow: a single fill bigger than any one truck's tanks (dual
  -- tanks ~ up to ~250 gal, so 200+ in ONE transaction means a second vehicle).
  insert into _findings
  select 'fuel_overflow:'||f.id, 'money', 'critical',
         'Oversized single fuel fill — truck '||coalesce(t.unit_number,'?'),
         round(f.gallons)::text||' gal in ONE transaction '||to_char(f.transaction_time,'Mon DD')
           ||coalesce(' at '||nullif(f.merchant_city,''),'')||' — exceeds a single truck''s tank.',
         'truck', f.truck_id
    from public.fuel_transactions f
    join public.trucks t on t.id = f.truck_id
   where f.gallons > 200 and f.transaction_time > now() - interval '30 days';

  -- (A "rapid re-fuel" check was evaluated and dropped: on this fuel-card data
  --  it fired almost entirely on single stops split into two lines — a big fill
  --  plus a small top-off/DEF minutes apart at the SAME station — i.e. noise, not
  --  theft. Product-mismatch + cash-advance + overflow + the Tier-2 recon below
  --  carry the real signal without the false positives.)

  -- 4) TIER 2 — fuel-vs-miles reconciliation. Miles = LOADED (dispatch) + EMPTY
  -- (deadhead), so a truck that deadheads a lot is not unfairly flagged. Expected
  -- gallons at 6.5 MPG vs actually purchased; a truck buying materially MORE than
  -- its miles justify is diverting fuel. Guarded on enough miles+gallons, so it
  -- stays quiet until fuel-card capture is reasonably complete (no false alarms).
  insert into _findings
  with mi as (
    select l.truck_id,
           sum(coalesce(l.miles,0) + coalesce(l.empty_miles,0)) as total_miles,
           sum(coalesce(l.empty_miles,0)) as deadhead
      from public.loads l
     where l.status in ('completed','billed')
       and l.delivery_time > now() - interval '45 days'
       and l.truck_id is not null
     group by l.truck_id
  ), fu as (
    select f.truck_id, sum(coalesce(f.gallons,0)) as gal
      from public.fuel_transactions f
     where coalesce(f.gallons,0) > 0 and f.transaction_time > now() - interval '45 days'
     group by f.truck_id
  )
  select 'fuel_recon:'||mi.truck_id, 'money', 'warn',
         'Truck '||coalesce(t.unit_number,'?')||' bought more fuel than its miles justify',
         'Drove '||mi.total_miles::text||' mi (incl '||mi.deadhead::text||' deadhead) in 45d -> ~'
           ||round(mi.total_miles/6.5)::text||' gal expected at 6.5 MPG, but purchased '||round(fu.gal)::text
           ||' gal ('||round((fu.gal/nullif(mi.total_miles/6.5,0)-1)*100)::text||'% over). Possible diversion.',
         'truck', mi.truck_id
    from mi
    join fu on fu.truck_id = mi.truck_id
    join public.trucks t on t.id = mi.truck_id
   where mi.total_miles >= 2000 and fu.gal >= 100
     and fu.gal >= (mi.total_miles/6.5) * 1.25;


  -- ===== FACTORING (added 2026-07-21) =====
  -- Reserve stuck: an invoice was factored 45+ days ago and the factor still
  -- hasn't released the reserve. The broker may well have paid the factor by
  -- now — that remainder is OUR money sitting at Denim. Chase the factor.
  insert into _findings
  select 'factor_reserve_stuck:'||i.id, 'cash',
         case when i.factored_at < now() - interval '75 days' then 'critical' else 'warn' end,
         'Factoring reserve stuck '||(now()::date - i.factored_at::date)||'d — '||i.invoice_number,
         '$'||round(public.invoice_balance(i))||' reserve on '||coalesce(c.company_name,'?')
           ||' unreleased since '||to_char(i.factored_at,'Mon DD')
           ||' ('||coalesce(i.factor_name,'factor')||'). Ask the factor for a settlement status.',
         'customer', i.customer_id
    from public.invoices i
    left join public.customers c on c.id = i.customer_id
   where i.factored_at is not null
     and i.status = 'sent'
     and public.invoice_balance(i) > 0
     and i.factored_at < now() - interval '45 days';


  -- Stranded accessorial (review H-1 net): an APPROVED accessorial whose load
  -- is already invoiced can never be picked up by create_invoice — the money
  -- is approved but uncollectable until someone voids & re-bills or issues a
  -- supplemental invoice. The propose-side filter prevents most of these; this
  -- catches the race (billed between propose and approve).
  insert into _findings
  select 'stranded_accessorial:'||a.id, 'money', 'critical',
         'Approved $'||round(a.amount)||' '||a.atype||' is stranded — load '||l.load_number||' already invoiced',
         initcap(a.atype)||' approved '||to_char(a.decided_at,'Mon DD')||' but the load was invoiced first. '
           ||'Void & re-bill the invoice (voiding reopens the accessorial) or issue a supplemental invoice.',
         'load', l.id
    from public.load_accessorials a
    join public.loads l on l.id = a.load_id
   where a.status = 'approved'
     and l.invoice_id is not null;

  -- ===== SECURITY: honeypot canaries =====
  -- Decoy objects (api_keys, bank_accounts) that nothing legitimate touches.
  -- Hits are recorded by app_private.honeypot_trip; one finding per object/day,
  -- kept alive 30 days so the team can't miss it.
  insert into _findings
  select 'honeypot:' || h.object || ':' || to_char(h.day, 'YYYY-MM-DD'),
         'compliance',
         case when h.worst >= 2 then 'critical' else 'warn' end,
         '🍯 Honeypot "' || h.object || '" accessed ' || h.hits || 'x on '
           || to_char(h.day, 'YYYY-MM-DD') || ' — possible compromise',
         'Decoy table read by: ' || h.whos || '. No legitimate Truxon code or user reads this object. '
           || case when h.worst >= 2
              then 'A NAMED account or database credential did this — treat those credentials as compromised: rotate keys and review the account''s activity.'
              else 'Only the public anon key was used (most likely an outside scanner probing the API). No real data was exposed — the decoy serves fakes — but watch for follow-up findings.' end,
         'security', null
  from (
    select hh.object, hh.hit_at::date as day, count(*) as hits,
           max(case when coalesce(hh.jwt_claims->>'role','') in ('authenticated','service_role')
                      or (hh.jwt_claims is null and coalesce(hh.db_role,'') not in ('authenticator','anon',''))
                    then 2 else 1 end) as worst,
           string_agg(distinct coalesce(hh.jwt_claims->>'email', hh.jwt_claims->>'role', hh.db_role, '?'), ', ') as whos
    from app_private.honeypot_hits hh
    where hh.hit_at > now() - interval '30 days'
    group by hh.object, hh.hit_at::date
  ) h;

  -- ===== SECURITY: permission-posture drift =====
  -- Anything the live posture has that the blessed baseline didn't: a new grant
  -- to anon/authenticated, a newly anon-callable function, or a table that lost
  -- RLS. anon exposure = critical; authenticated / RLS-off = warn.
  insert into _findings
  select 'posture_drift:' || d.kind || ':' || left(regexp_replace(d.item,'[^a-zA-Z0-9_ .]','','g'), 80),
         'compliance',
         case when d.item like 'anon %' or d.kind = 'routine' then 'critical' else 'warn' end,
         case d.kind
           when 'grant'   then '🔓 New table permission: ' || d.item
           when 'routine' then '🔓 Function now callable by anon: ' || d.item
           when 'rls_off' then '🔓 Row-level security is OFF on ' || d.item
         end,
         'The database''s access posture changed from the blessed baseline. '
           || case d.kind
                when 'grant'   then 'A role gained a table privilege it did not have before (' || d.item || '). '
                when 'routine' then 'The public anon key can now execute this function (' || d.item || '). '
                when 'rls_off' then 'This table''s row-level security is disabled, so its policies are not enforced. '
              end
           || 'If you made this change on purpose, re-bless the baseline (Admin → security). If not, an unauthorized grant may have been added — review it and the security audit log immediately.',
         'security', null
  from (
    select kind, item from app_private.security_posture()
    except
    select kind, item from app_private.security_baseline
  ) d;

  -- ===== SECURITY: admin grants =====
  -- Every elevation to admin (from the audit log the profiles tripwire writes)
  -- surfaces as a critical finding until acknowledged. Legit changes you ack;
  -- an unexpected one is an account takeover in progress.
  insert into _findings
  select 'admin_granted:' || a.id::text, 'compliance', 'critical',
         '🛡️ Admin access granted' || coalesce(' to ' || (a.detail->>'username'), ''),
         'An account was made an administrator on ' || to_char(a.at,'Mon DD HH24:MI')
           || coalesce(' by ' || a.actor_email, ' (no signed-in user — a direct database change)')
           || ' (was: ' || coalesce(a.detail->>'from','?') || '). If this was you or an authorized change, '
           || 'acknowledge it. If not, an intruder''s first move is to grant themselves admin — revoke it and '
           || 'rotate credentials now. Full record in the security audit log.',
         'profile', null
  from app_private.security_audit a
  where a.event_type = 'admin_granted' and a.at > now() - interval '30 days';

  -- ===== SECURITY: canary account =====
  -- Any auth activity against the permanently-inactive canary login means
  -- someone is enumerating/spraying your user list. Scans the GoTrue audit log.
  insert into _findings
  select 'canary_user:' || to_char(max(a.created_at), 'YYYYMMDDHH24'),
         'compliance', 'critical',
         '🕵️ Canary login touched — user-list enumeration',
         'The dormant canary account (ap-archive@aidalogistics.com) saw ' || count(*)
           || ' authentication event(s) since ' || to_char(min(a.created_at),'Mon DD HH24:MI')
           || '. Nobody knows its password and it can never log in, so this is someone working through your '
           || 'user list — likely credential spraying. Consider forcing a password reset on all office accounts '
           || 'and check the security audit log for successful logins elsewhere.',
         'security', null
  from auth.audit_log_entries a
  where a.created_at > now() - interval '24 hours'
    and a.payload::text ilike '%ap-archive@aidalogistics.com%'
  having count(*) > 0;

  -- ===== CASH: detention review queue aging =====
  -- The daily cron PROPOSES detention accessorials; only an office click turns
  -- them into invoice money. If proposals sit undecided >48h they quietly age
  -- past billing windows — one standing nudge until the queue is cleared.
  insert into _findings
  select 'accessorial_review_queue', 'cash', 'warn',
         '⏱️ ' || count(*) || ' proposed detention charge' || case when count(*) = 1 then '' else 's' end
           || ' (~$' || round(sum(a.amount)) || ') await' || case when count(*) = 1 then 's' else '' end || ' review',
         count(*) || ' detention accessorial' || case when count(*) = 1 then ' has' else 's have' end
           || ' been sitting in "proposed" for over 48 hours (~$' || round(sum(a.amount))
           || ' total, oldest from ' || to_char(min(a.created_at), 'Mon DD') || '). Approve or reject them on '
           || 'Accounting → Detention ("Bill it") — approved charges ride the next invoice automatically, but '
           || 'nothing bills while they wait, and brokers get less cooperative as the delivery ages.',
         'invoice', null
    from public.load_accessorials a
   where a.status = 'proposed' and a.created_at < now() - interval '48 hours'
  having count(*) > 0;

  -- ===== OPS: off-site db-backup freshness =====
  -- The nightly db-backup edge fn dumps to the private db-backups bucket; the
  -- watchdog only watches the NAS heartbeat, so a silently-broken bucket cron
  -- would go unnoticed until a restore is needed. Quiet where the bucket does
  -- not exist (local/dev).
  insert into _findings
  select 'backup_bucket_stale', 'compliance', 'critical',
         '💾 Off-site database backup is stale',
         'The db-backups bucket''s newest object is from '
           || coalesce(to_char((select max(o.created_at) from storage.objects o where o.bucket_id = 'db-backups'), 'Mon DD HH24:MI'), 'NEVER')
           || ' — more than 36h ago. The nightly dump (03:37 UTC) is not landing. Check the db-backup '
           || 'edge function logs and the pg_cron schedule; a business without a fresh backup is one '
           || 'ransomware event away from losing books.',
         'security', null
   where exists (select 1 from storage.buckets b where b.id = 'db-backups')
     and coalesce((select max(o.created_at) from storage.objects o where o.bucket_id = 'db-backups'),
                  'epoch'::timestamptz) < now() - interval '36 hours';

  -- ===== SECURITY: nobody has MFA yet =====
  -- Standing nudge while ZERO office users have a verified second factor;
  -- resolves itself the moment the first one enrolls.
  insert into _findings
  select 'mfa_coverage_zero', 'compliance', 'warn',
         '🔐 No office account has two-factor auth yet',
         'MFA is live (My Account → Two-factor authentication) but no admin, dispatcher, accountant or '
           || 'maintenance account has enrolled an authenticator app. A single phished password is currently '
           || 'enough to reach the books. Enrolling takes about a minute.',
         'security', null
   where not exists (
     select 1 from auth.mfa_factors f
       join public.profiles p on p.id = f.user_id and p.is_active
         and p.role in ('admin','dispatcher','accountant','maintenance')
      where f.status = 'verified')
     and exists (select 1 from public.profiles where is_active
                   and role in ('admin','dispatcher','accountant','maintenance'));

  -- ===== CASH: broken promise-to-pay =====
  -- A broker's most-recent promised pay date on an invoice has passed and the
  -- invoice is still unpaid. Each is a warm collections lead the office already
  -- worked once — chase it before it goes cold. One finding per invoice; clears
  -- when it's paid or a new promise is logged.
  insert into _findings
  select 'broken_promise:' || p.invoice_id,
         'cash', 'warn',
         '🤝 Broken promise-to-pay — ' || coalesce(c.company_name, 'a broker') || ' inv ' || i.invoice_number,
         coalesce(c.company_name, 'A broker') || ' promised to pay invoice ' || i.invoice_number
           || ' (~$' || round(public.invoice_balance(i)) || ') by ' || to_char(p.promised_date, 'Mon DD')
           || ' but it''s still open ' || (current_date - p.promised_date) || ' day(s) later. Call them back — '
           || 'a missed promise is the strongest signal to escalate. See Accounting → Collections.',
         'invoice', p.invoice_id
    from (
      select distinct on (cn.invoice_id) cn.invoice_id, cn.promised_date
        from public.collection_notes cn
       where cn.invoice_id is not null and cn.promised_date is not null
       order by cn.invoice_id, cn.created_at desc, cn.id desc
    ) p
    join public.invoices i on i.id = p.invoice_id
    left join public.customers c on c.id = i.customer_id
   where p.promised_date < current_date
     and i.status = 'sent'
     and public.invoice_balance(i) > 0;

  -- ===== CASH: customer over credit exposure =====
  -- A broker's total float (open AR + unbilled + committed open loads) is past
  -- the pay-history-derived limit — book more and you're financing them. One
  -- finding per customer; clears when they pay down or the limit rises.
  insert into _findings
  select 'over_exposure:' || e.customer_id, 'cash', 'warn',
         '🚦 ' || e.company_name || ' is over its credit exposure limit',
         e.company_name || ' is carrying $' || e.exposure || ' of exposure (open AR + unbilled + committed '
           || 'loads) against a $' || e.credit_limit || ' limit — $' || e.over_by || ' over'
           || coalesce(', and averages ' || round(e.avg_days_to_pay) || ' days to pay', '')
           || '. Get paid down or hold new bookings before you extend more credit. Booking screen shows the same guard.',
         'customer', e.customer_id
    from public.customers_over_exposure() e;

  -- ===== REVENUE: a regular broker has gone quiet (churn risk) =====
  -- A customer who shipped on a steady cadence and has now been silent for well
  -- past that cadence is early churn — cheaper to win back now than to replace.
  -- Resolves the moment they book again.
  insert into _findings
  select 'customer_quiet:' || q.customer_id, 'cash', 'warn',
         '📉 ' || q.company_name || ' has gone quiet',
         q.company_name || ' shipped ' || q.prior_loads || ' load(s) in the prior 180 days (about one every '
           || round(q.cadence_days) || ' days) but nothing in the last ' || q.days_since || ' days. A regular '
           || 'broker going silent is early churn — a call now is cheaper than replacing the revenue. '
           || 'Their full history is on the customer page.',
         'customer', q.customer_id
    from (
      select c.id as customer_id, c.company_name,
             count(l.id) as prior_loads,
             floor(extract(epoch from (now() - max(l.created_at))) / 86400.0)::int as days_since,
             180.0 / nullif(count(l.id), 0) as cadence_days
        from public.customers c
        join public.loads l on l.customer_id = c.id and l.created_at >= now() - interval '180 days'
       group by c.id, c.company_name
    ) q
   where q.prior_loads >= 4
     and q.days_since > greatest(45, (2 * q.cadence_days)::int);

  -- ===== DATA: revenue-integrity gaps on billed/completed loads =====
  -- A completed or billed load with no rate or no miles silently distorts every
  -- $/mile, margin, and break-even number it touches. One rolling finding lists
  -- the offenders (last 120 days) so the office can patch them in a batch.
  insert into _findings
  select 'load_data_gaps', 'data', 'warn',
         '🧮 ' || count(*) || ' billed/completed load(s) missing rate or miles',
         count(*) || ' load(s) delivered in the last 120 days have no rate and/or no miles, so they drag down '
           || 'every revenue-per-mile, margin, and break-even figure they touch. Fix them on the load record: '
           || string_agg(l.load_number || ' (' ||
                case when coalesce(l.rate,0) = 0 and coalesce(l.miles,0) = 0 then 'no rate + miles'
                     when coalesce(l.rate,0) = 0 then 'no rate'
                     else 'no miles' end || ')', ', ' order by l.delivery_time desc),
         'load', null
    from public.loads l
   where l.status in ('completed','billed')
     and l.delivery_time >= now() - interval '120 days'
     and (coalesce(l.rate,0) = 0 or coalesce(l.miles,0) = 0)
  having count(*) > 0;

  -- ===== DATA (customer regulatory-number quality) =====
  -- Structurally-invalid MC/USDOT stored on active customers (USDOT = 5-8 digits,
  -- MC docket = 5-7 digits), or a customer carrying one identifier but not the
  -- other (usually an incomplete/mis-scanned record). Report-only: FMCSA content
  -- verification is enforced at write time (_shared/fmcsa.ts); this catches numbers
  -- that were already stored before that gate existed.
  insert into _findings
  select 'cust_dot_malformed:'||c.id, 'data', 'warn',
         'Customer "'||c.company_name||'" has a malformed USDOT number',
         'Stored USDOT "'||c.usdot_number||'" is not 5-8 digits - likely an OCR or import error',
         'customer', c.id
    from public.customers c
   where coalesce(c.do_not_use,false) = false
     and nullif(btrim(coalesce(c.usdot_number,'')),'') is not null
     and regexp_replace(c.usdot_number,'\D','','g') !~ '^\d{5,8}$';

  insert into _findings
  select 'cust_mc_malformed:'||c.id, 'data', 'warn',
         'Customer "'||c.company_name||'" has a malformed MC number',
         'Stored MC "'||c.mc_number||'" is not 5-7 digits - likely an OCR or import error',
         'customer', c.id
    from public.customers c
   where coalesce(c.do_not_use,false) = false
     and nullif(btrim(coalesce(c.mc_number,'')),'') is not null
     and regexp_replace(c.mc_number,'\D','','g') !~ '^\d{5,7}$';

  -- ===== OPS: chronic idlers (R8 Block 2) =====
  -- Trucks burning >35% of engine-on time stationary over the last 14 days,
  -- with a >=7-idle-hour floor so a truck barely driven can't trip it.
  -- Waste estimate: ~0.8 gal/hr idle burn at the fleet's actual avg $/gal.
  insert into _findings
  select 'idle_chronic:'||(t->>'truck_id'), 'ops', 'warn',
         'Unit '||coalesce(tr.unit_number, '?')||' idles '||(t->>'idle_pct')||'% of engine time',
         'Last 14 days: '||(t->>'idle_hours')||' idle hours (~'
           ||round((t->>'idle_hours')::numeric * 0.8, 0)||' gal, ~$'
           ||round((t->>'idle_hours')::numeric * 0.8 * coalesce((
               select sum(coalesce(net_of_discount, amount)) / nullif(sum(gallons), 0)
                 from public.fuel_transactions
                where status <> 'Declined' and fuel_type = 'Diesel'
                  and transaction_time > now() - interval '30 days'), 3.85), 0)
           ||' burned standing still)',
         'truck', (t->>'truck_id')::bigint
    from jsonb_array_elements(public.idle_summary(14)->'trucks') t
    left join public.trucks tr on tr.id = (t->>'truck_id')::bigint
   where (t->>'idle_pct')::numeric > 35
     and (t->>'idle_hours')::numeric >= 7;

  -- ===== OPS: speeding (R8 Block 7) =====
  -- warn at >=30 min over 75 mph in 14d; critical at >=15 min over 80.
  insert into _findings
  select 'speeding_hot:'||(t->>'truck_id'),
         'ops',
         case when (t->>'min_over_80')::numeric >= 15 then 'critical' else 'warn' end,
         'Unit '||(t->>'unit')||' speeding - '||(t->>'min_over_75')||' min at 75+ mph (14d)',
         'Max '||(t->>'max_speed')||' mph'
           ||coalesce(' near '||nullif(t->>'worst_place',''),'')
           ||coalesce(' at '||to_char((t->>'worst_at')::timestamptz,'Mon DD HH24:MI'),'')
           ||'. '||(t->>'min_over_80')||' min at 80+. CSA Unsafe Driving BASIC + insurance exposure.',
         'truck', (t->>'truck_id')::bigint
    from jsonb_array_elements(public.speeding_summary(14)->'trucks') t
   where (t->>'min_over_75')::numeric >= 30
      or (t->>'min_over_80')::numeric >= 15;

  -- ===== MAINTENANCE: dark ELD units (R8 Block 12b) =====
  -- Active (non-retired) trucks whose ELD hasn't reported in 48h - or that
  -- have no linked ELD at all. Grace: trucks created in the last 7 days.
  insert into _findings
  select 'eld_dark:'||t.id, 'maintenance',
         case when le.last_ts is null or le.last_ts < now() - interval '14 days'
              then 'critical' else 'warn' end,
         'Unit '||t.unit_number||' ELD is dark',
         case when le.last_ts is null
              then 'No ELD is linked to this truck - HOS logs, GPS, odometer, and IFTA miles are all blind.'
              else 'Last ELD report '||to_char(le.last_ts, 'Mon DD HH24:MI')||' ('
                   ||extract(day from now() - le.last_ts)||' days ago). HOS compliance and all telematics analytics are blind for this unit.' end,
         'truck', t.id
    from public.trucks t
    left join lateral (
      select max(vs.ts) as last_ts
        from public.eld_vehicles ev
        join public.eld_vehicle_status vs on vs.vehicle_id = ev.vehicle_id
       where ev.truck_id = t.id and ev.active
    ) le on true
   where t.status <> 'retired'
     and coalesce(t.created_at, now()) < now() - interval '7 days'
     and (le.last_ts is null or le.last_ts < now() - interval '48 hours');

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

-- CREATE OR REPLACE resets function-level SET options — re-pin the timeout
-- headroom from 20260722013003 or the next redefinition silently reverts the
-- scan to the ~8s authenticated default. EVERY future sentinel_scan
-- redefinition must carry this line.
alter function public.sentinel_scan() set statement_timeout to '120s';
