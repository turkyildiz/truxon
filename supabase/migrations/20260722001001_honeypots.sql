-- ============================================================================
-- Database honeypots (intrusion canaries).
-- Two decoy objects — public.api_keys and public.bank_accounts — that look
-- irresistible to an intruder and are touched by NOTHING legitimate: no page,
-- no job, no report, no agent (trux_query refuses them by name). Any read is
-- therefore an intrusion indicator. Each decoy is a view over a SECURITY
-- DEFINER function that returns plausible fake rows and silently records WHO
-- asked (JWT claims, session role, caller IP/user-agent) to
-- app_private.honeypot_hits, then kicks an immediate Sentinel scan so the
-- owner gets a push within seconds.
--
-- Capture is rollback-proof: PostgREST runs GETs in READ ONLY transactions
-- (a local INSERT would fail) and a careful attacker can ROLLBACK a psql
-- session — so the primary recording path is dblink (an autonomous second
-- connection that commits independently), using the DSN stored in
-- app_private.cron_config under 'hp_dsn' (set at deploy time via
-- set_cron_config, NEVER in git). Fallback: local insert; last resort:
-- RAISE LOG (visible in platform logs). The decoy NEVER errors — to the
-- intruder it is just a boring table.
--
-- Severity: anon-key hits = warn (public key, likely an outside scanner);
-- authenticated / service_role / direct-DB hits = critical (a named account
-- or a database credential is compromised).
--
-- ⚠️  Do not open these tables in Studio or query them ad hoc — you will
--     page the owner. That is the point.
-- ============================================================================

create extension if not exists dblink with schema extensions;

create table if not exists app_private.honeypot_hits (
  id bigint generated always as identity primary key,
  object text not null,
  hit_at timestamptz not null default now(),
  db_role text,          -- session_user: 'authenticator' = via API, else a DB credential
  jwt_claims jsonb,      -- who, per the API JWT (role / sub / email)
  headers jsonb,         -- x-real-ip, user-agent, …
  via text not null default 'direct'   -- direct | dblink
);
create index if not exists honeypot_hits_at_idx on app_private.honeypot_hits (hit_at desc);

create or replace function app_private.honeypot_record(
  p_object text, p_db_role text, p_claims jsonb, p_headers jsonb, p_via text)
returns void
language plpgsql security definer set search_path = public, app_private
as $$
declare
  v_recent int;
begin
  select count(*) into v_recent from app_private.honeypot_hits
   where hit_at > now() - interval '10 minutes';
  insert into app_private.honeypot_hits (object, db_role, jwt_claims, headers, via)
  values (p_object, p_db_role, p_claims, p_headers, p_via);
  -- instant alarm (sentinel scan pushes new criticals), throttled to 1/10min
  if v_recent = 0 then
    begin
      perform app_private.cron_edge_call('trux-sentinel', '{"mode":"scan"}'::jsonb);
    exception when others then null;
    end;
  end if;
end;
$$;
revoke all on function app_private.honeypot_record(text, text, jsonb, jsonb, text) from public, anon, authenticated;

create or replace function app_private.honeypot_trip(p_object text)
returns void
language plpgsql security definer set search_path = public, app_private
as $$
declare
  v_claims  jsonb := nullif(current_setting('request.jwt.claims', true), '')::jsonb;
  v_headers jsonb := nullif(current_setting('request.headers', true), '')::jsonb;
  v_srole   text  := session_user::text;
  v_dsn     text;
  v_done    boolean := false;
begin
  raise log 'HONEYPOT tripped: % (session=% api_role=%)',
    p_object, v_srole, coalesce(v_claims->>'role', 'none');
  -- primary: autonomous connection — survives the caller's READ ONLY txn
  -- (PostgREST GET) and survives an attacker's ROLLBACK
  select value into v_dsn from app_private.cron_config where key = 'hp_dsn';
  if coalesce(v_dsn, '') <> '' then
    begin
      perform extensions.dblink_exec(v_dsn, format(
        'select app_private.honeypot_record(%L, %L, %L::jsonb, %L::jsonb, %L)',
        p_object, v_srole, v_claims::text, v_headers::text, 'dblink'));
      v_done := true;
    exception when others then
      raise log 'HONEYPOT dblink record failed: %', sqlerrm;
    end;
  end if;
  if not v_done then
    begin
      perform app_private.honeypot_record(p_object, v_srole, v_claims, v_headers, 'direct');
    exception when others then
      raise log 'HONEYPOT local record failed: %', sqlerrm;
    end;
  end if;
end;
$$;
revoke all on function app_private.honeypot_trip(text) from public, anon, authenticated;

-- ---- decoy: api_keys ----
create or replace function public._hp_api_keys()
returns table(id int, service text, environment text, api_key text, created_at timestamptz, last_used_at timestamptz)
language plpgsql security definer set search_path = public, app_private
as $$
begin
  perform app_private.honeypot_trip('api_keys');
  -- fake keys are built by concatenation so GitHub secret-scanning push
  -- protection doesn't mistake them for real vendor credentials (it did);
  -- the intruder still sees one convincing contiguous string
  return query values
    (1, 'quickbooks', 'production', 'qbo_prd_' || '8Kx2mVw4pTnR7cJhL0aE3yBqZs6NdUgF', now() - interval '312 days', now() - interval '2 days'),
    (2, 'stripe',     'production', 'sk_live_' || '51JxK8mLzT2vQwR4eYpN7cHb9DgA3fUjX', now() - interval '290 days', now() - interval '31 days'),
    (3, 'samsara',    'production', 'samsara_api_' || 'yJ3kP8wQx5RmN2vC7tZbH4dLgE9aUf', now() - interval '201 days', now() - interval '1 day'),
    (4, 'denim',      'production', 'dnm_' || 'k9Q2wE5rT8yU1iO4pA7sD0fG3hJ6kL9zXcVb', now() - interval '44 days',  now() - interval '3 hours');
end;
$$;
revoke all on function public._hp_api_keys() from public, anon, authenticated;

create or replace view public.api_keys as select * from public._hp_api_keys();
grant select on public.api_keys to anon, authenticated, service_role;

-- ---- decoy: bank_accounts ----
create or replace function public._hp_bank_accounts()
returns table(id int, account_name text, bank_name text, routing_number text, account_number text, account_type text, active boolean)
language plpgsql security definer set search_path = public, app_private
as $$
begin
  perform app_private.honeypot_trip('bank_accounts');
  return query values
    (1, 'Aida Logistics Operating', 'Chase',   '021000021', '882405193',  'checking', true),
    (2, 'Aida Logistics Payroll',   'Chase',   '021000021', '882417726',  'checking', true),
    (3, 'Fuel Reserve',             'Mercury', '084106768', '9800214455', 'savings',  true);
end;
$$;
revoke all on function public._hp_bank_accounts() from public, anon, authenticated;

create or replace view public.bank_accounts as select * from public._hp_bank_accounts();
grant select on public.bank_accounts to anon, authenticated, service_role;

-- ---- Forest must never trip the wire: trux_query refuses decoys by name ----
create or replace function public.trux_query(p_sql text)
returns jsonb
language plpgsql security invoker
as $$
declare
  q text := btrim(p_sql);
  result jsonb;
begin
  if public.my_role() is null then
    raise exception 'Not authenticated';
  end if;
  if q !~* '^\s*(select|with)\y' then
    raise exception 'Only SELECT queries are allowed';
  end if;
  if q ~* '\m(insert|update|delete|truncate|drop|alter|create|grant|revoke|copy|vacuum|call|do|set|reset|listen|notify|refresh)\M' then
    raise exception 'Query contains a disallowed keyword — read-only SELECT only';
  end if;
  if q like '%;%' then
    raise exception 'Multiple statements are not allowed';
  end if;
  if q ~* '\m(api_keys|bank_accounts|honeypot_hits)\M' or q ~* '_hp_' then
    raise exception 'That table is restricted';
  end if;

  perform set_config('statement_timeout', '4000', true);
  perform set_config('transaction_read_only', 'on', true);

  execute format('select coalesce(jsonb_agg(t), ''[]''::jsonb) from (select * from (%s) q limit 200) t', q)
    into result;
  return result;
end;
$$;

revoke execute on function public.trux_query(text) from public, anon;
grant execute on function public.trux_query(text) to authenticated;

-- ---- sentinel_scan: honeypot check spliced in (full redefinition) ----
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

-- ---- insight_detail: honeypot why + evidence branch (full redefinition) ----
create or replace function public.insight_detail(p_id bigint)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  ins       public.trux_insights;
  prefix    text;
  subject   text;
  why       text;
  records   jsonb := '[]'::jsonb;
begin
  if auth.role() <> 'service_role' and coalesce(public.my_role()::text,'none') not in ('admin','accountant','dispatcher') then
    raise exception 'Not enough permissions';
  end if;

  select * into ins from public.trux_insights where id = p_id;
  if not found then raise exception 'Insight not found'; end if;
  prefix := split_part(ins.dedup_key, ':', 1);

  -- ---- why Forest flagged it (the rule, in plain English) ----
  why := case prefix
    when 'fuel_product'  then 'A diesel truck physically cannot burn gasoline or ethanol (E85). Buying it on this truck''s fuel card means the fuel is going into another vehicle, a can, or being resold — classic card misuse. Every non-diesel fill on this card in the last 30 days is listed below.'
    when 'fuel_cash'     then 'A fuel card is for fuel. Charges with 0 gallons are cash advances or fees — a common leakage/theft vector. Forest flags a truck whose non-fuel charges top $500 in 30 days (critical over $2,000, or when they exceed the truck''s actual diesel spend). Each such charge is listed below.'
    when 'fuel_overflow' then 'This single transaction is larger than any one truck''s tanks can hold (>200 gal), so part of the fuel went into a second tank or a different vehicle.'
    when 'fuel_recon'    then 'Forest compared gallons purchased against the miles this truck actually drove — dispatch (loaded) PLUS deadhead (empty) — at ~6.5 MPG over 45 days. It bought materially more fuel than those miles justify, so the excess may be diverted. Deadhead is included so a truck that runs empty a lot is not flagged unfairly.'
    when 'factor_reserve_stuck' then 'This invoice was sold to the factor over 45 days ago and the reserve portion still hasn''t been released. Brokers usually pay the factor within that window, so the remainder is likely YOUR money sitting at the factor — ask them for a settlement status on this invoice.'
    when 'honeypot' then 'These decoy records exist for exactly one reason: to catch intruders. Nothing in Truxon — no page, no job, no report, not even Forest — ever reads this table, so ANY access means someone is exploring the database who should not be. The rows below show exactly who, from where, and when. If this was not you or an authorized security test, rotate the affected keys immediately.'
    when 'unprofitable_truck' then 'This truck''s fuel cost exceeded the revenue it earned this week.'
    when 'toll_violation'     then 'This toll posted as a VIOLATION (a missed or unpaid toll), which is billed at a penalty rate above the normal toll — an avoidable cost.'
    when 'detention'          then 'ELD dwell time shows this truck sat past the free time at a stop, so the broker owes detention — bill it before the 14-day window closes.'
    else coalesce(ins.detail, 'Forest surfaced this from the scheduled scan.')
  end;

  -- ---- evidence records, per finding type ----
  if prefix in ('fuel_product','fuel_cash','fuel_recon','unprofitable_truck') then
    select 'Truck '||coalesce(t.unit_number,'?') into subject from public.trucks t where t.id = ins.entity_id;
    select coalesce(jsonb_agg(r order by (r->>'when') desc), '[]'::jsonb) into records
    from (
      select jsonb_build_object(
        'when',     to_char(f.transaction_time, 'YYYY-MM-DD HH24:MI'),
        'driver',   coalesce(nullif(f.driver_name,''), (select d.full_name from public.drivers d where d.id = f.driver_id), '—'),
        'card',     case when coalesce(f.card_last_four,'') <> '' then '…'||f.card_last_four else '—' end,
        'merchant', coalesce(nullif(f.merchant,''), '—'),
        'location', coalesce(nullif(f.merchant_city,''),'?')||coalesce(', '||nullif(f.merchant_state,''),''),
        'product',  coalesce(nullif(f.fuel_type,''), '—'),
        'gallons',  coalesce(f.gallons, 0),
        'amount',   coalesce(f.amount, 0)
      ) as r
      from public.fuel_transactions f
      where f.truck_id = ins.entity_id
        and f.transaction_time > now() - interval '45 days'
        and (prefix <> 'fuel_product' or lower(coalesce(f.fuel_type,'')) ~ '(unleaded|ethanol|gasoline|premium|regular|e85|midgrade)')
        and (prefix <> 'fuel_cash'    or (coalesce(f.gallons,0) = 0 and f.amount > 0))
    ) x;

  elsif prefix = 'fuel_overflow' then
    select 'Truck '||coalesce(t.unit_number,'?') into subject from public.trucks t where t.id = ins.entity_id;
    select jsonb_build_array(jsonb_build_object(
      'when',     to_char(f.transaction_time,'YYYY-MM-DD HH24:MI'),
      'driver',   coalesce(nullif(f.driver_name,''),'—'),
      'card',     case when coalesce(f.card_last_four,'')<>'' then '…'||f.card_last_four else '—' end,
      'merchant', coalesce(nullif(f.merchant,''),'—'),
      'location', coalesce(nullif(f.merchant_city,''),'?')||coalesce(', '||nullif(f.merchant_state,''),''),
      'product',  coalesce(nullif(f.fuel_type,''),'—'),
      'gallons',  coalesce(f.gallons,0), 'amount', coalesce(f.amount,0)))
    into records
    from public.fuel_transactions f where f.id = nullif(split_part(ins.dedup_key,':',2),'')::bigint;

  elsif prefix = 'toll_violation' then
    select jsonb_build_array(jsonb_build_object(
      'when',     to_char(coalesce(tt.post_date_time, tt.exit_date_time),'YYYY-MM-DD HH24:MI'),
      'unit',     coalesce(nullif(tt.vehicle_number,''),'—'),
      'plate',    coalesce(nullif(tt.plate_number,''),'—'),
      'agency',   coalesce(nullif(tt.toll_agency_name,''),'—')||coalesce(' ('||nullif(tt.toll_agency_state,'')||')',''),
      'plaza',    coalesce(nullif(tt.exit_plaza_name,''), nullif(tt.entry_plaza_name,''), '—'),
      'charge',   coalesce(tt.toll_charge,0)))
    into records
    from public.toll_transactions tt where tt.id = nullif(split_part(ins.dedup_key,':',2),'')::bigint;
    select 'Toll' into subject;

  elsif ins.entity_type = 'customer' then
    select company_name into subject from public.customers where id = ins.entity_id;
    select coalesce(jsonb_agg(r order by (r->>'issued')), '[]'::jsonb) into records from (
      select jsonb_build_object(
        'invoice', i.invoice_number,
        'issued',  to_char(i.created_at,'YYYY-MM-DD'),
        'amount',  coalesce(i.total, 0),
        'status',  i.status,
        'paid',    coalesce(to_char(i.paid_at,'YYYY-MM-DD'),'unpaid')
      ) as r
      from public.invoices i
      where i.customer_id = ins.entity_id and coalesce(i.paid_at, null) is null
      order by i.created_at limit 50
    ) x;

  elsif ins.entity_type = 'load' then
    select jsonb_build_array(jsonb_build_object(
      'load',      l.load_number, 'status', l.status,
      'lane',      coalesce(l.pickup_state,'?')||' -> '||coalesce(l.delivery_state,'?'),
      'delivery',  to_char(l.delivery_time,'YYYY-MM-DD HH24:MI'),
      'rate',      coalesce(l.rate,0),
      'driver',    (select d.full_name from public.drivers d where d.id = l.driver_id),
      'truck',     (select t.unit_number from public.trucks t where t.id = l.truck_id)))
    into records
    from public.loads l where l.id = ins.entity_id;
    select 'Load '||coalesce((select load_number from public.loads where id = ins.entity_id),'?') into subject;

  elsif ins.entity_type = 'driver' then
    select d.full_name into subject from public.drivers d where d.id = ins.entity_id;
    select jsonb_build_array(jsonb_build_object(
      'driver', d.full_name, 'status', d.status,
      'license', coalesce(nullif(d.license_number,''),'—'),
      'license_expires', coalesce(to_char(d.license_expiration,'YYYY-MM-DD'),'—'),
      'phone', coalesce(nullif(d.phone,''),'—')))
    into records from public.drivers d where d.id = ins.entity_id;

  elsif prefix = 'honeypot' then
    subject := 'Decoy "' || split_part(ins.dedup_key, ':', 2) || '"';
    select coalesce(jsonb_agg(r order by (r->>'when') desc), '[]'::jsonb) into records
    from (
      select jsonb_build_object(
        'when',     to_char(h.hit_at, 'YYYY-MM-DD HH24:MI:SS'),
        'who',      coalesce(h.jwt_claims->>'email', h.jwt_claims->>'sub', '—'),
        'api_role', coalesce(h.jwt_claims->>'role', '(direct DB: ' || coalesce(h.db_role,'?') || ')'),
        'ip',       coalesce(h.headers->>'x-real-ip', h.headers->>'cf-connecting-ip', h.headers->>'x-forwarded-for', '—'),
        'client',   left(coalesce(h.headers->>'user-agent', '—'), 60)
      ) as r
      from app_private.honeypot_hits h
      where h.object = split_part(ins.dedup_key, ':', 2)
        and h.hit_at::date = split_part(ins.dedup_key, ':', 3)::date
      limit 100
    ) x;

  elsif ins.entity_type = 'truck' then
    select 'Truck '||coalesce(unit_number,'?') into subject from public.trucks where id = ins.entity_id;
    select jsonb_build_array(jsonb_build_object(
      'unit', t.unit_number, 'status', t.status,
      'plate', coalesce(nullif(t.plate_number,''),'—'),
      'plate_expires', coalesce(to_char(t.plate_expiry,'YYYY-MM-DD'),'—')))
    into records from public.trucks t where t.id = ins.entity_id;
  end if;

  return jsonb_build_object(
    'id', ins.id, 'title', ins.title, 'detail', ins.detail,
    'severity', ins.severity, 'category', ins.category,
    'first_seen', ins.first_seen, 'last_seen', ins.last_seen,
    'subject', coalesce(subject, ins.entity_type),
    'why', why,
    'records', records
  );
end;
$$;

revoke execute on function public.insight_detail(bigint) from public, anon;
grant execute on function public.insight_detail(bigint) to authenticated, service_role;
