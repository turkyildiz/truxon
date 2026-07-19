-- Trux Sentinel — the proactive "checks everything" layer. A scheduled scan
-- runs deterministic business checks (money leaks, cash/AR, ops risk,
-- compliance) and records what it notices as trux_insights. Detection is pure
-- SQL (cheap, exact, runs often); the LLM only synthesizes/prioritizes for the
-- daily brief. Insights dedup on a stable key (re-firing updates last_seen, it
-- doesn't duplicate) and auto-resolve when their condition clears — the same
-- flap-suppression the system watchdog uses, so you get signal not noise.

create table if not exists public.trux_insights (
  id bigint generated always as identity primary key,
  dedup_key text not null unique,                 -- e.g. 'late_load:42'
  category text not null check (category in ('money','cash','ops','compliance')),
  severity text not null check (severity in ('info','warn','critical')),
  title text not null,
  detail text not null default '',
  entity_type text not null default '',            -- load / driver / truck / customer / invoice
  entity_id bigint,
  status text not null default 'open' check (status in ('open','acknowledged','resolved')),
  first_seen timestamptz not null default now(),
  last_seen timestamptz not null default now(),
  acknowledged_by uuid references public.profiles (id),
  acknowledged_at timestamptz,
  resolved_at timestamptz
);

create index if not exists trux_insights_open_idx on public.trux_insights (category, severity) where status <> 'resolved';
create index if not exists trux_insights_seen_idx on public.trux_insights (last_seen desc);

alter table public.trux_insights enable row level security;

-- Owner/finance/ops can see what Trux noticed; all writes go through the
-- SECURITY DEFINER scan (service role) or the acknowledge RPC.
drop policy if exists trux_insights_read on public.trux_insights;
create policy trux_insights_read on public.trux_insights
  for select to authenticated using (public.my_role() in ('admin','accountant','dispatcher'));

-- ---------- the scan ----------
-- Gathers every currently-firing finding, upserts them (re-opening a resolved
-- one that recurs), then resolves any open insight that is no longer firing.
create or replace function public.sentinel_scan()
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  fired int;
  resolved int;
begin
  if auth.role() <> 'service_role' and public.my_role() <> 'admin' then
    raise exception 'Not enough permissions';
  end if;

  -- drop-if-exists so the function is re-callable within one transaction
  -- (on commit drop alone only cleans up at commit).
  drop table if exists _findings;
  create temp table _findings (
    dedup_key text primary key, category text, severity text, title text,
    detail text, entity_type text, entity_id bigint
  ) on commit drop;

  -- ===== MONEY LEAKS =====
  -- Toll violations in the last 7 days (each is an avoidable overage).
  insert into _findings
  select 'toll_violation:'||t.id, 'money',
         case when t.toll_charge >= 50 then 'critical' else 'warn' end,
         'Toll violation — '||coalesce(nullif(t.toll_agency_name,''),'unknown agency'),
         'Violation toll $'||t.toll_charge||' on unit '||coalesce(nullif(t.vehicle_number,''),'?')
           ||coalesce(' ('||nullif(t.toll_agency_state,'')||')',''),
         'truck', t.truck_id
    from public.toll_transactions t
   where t.toll_category = 'Violation'
     and coalesce(t.post_date_time, t.exit_date_time) > now() - interval '7 days';

  -- Trucks running unprofitable this week (revenue < fuel this week).
  insert into _findings
  select 'unprofitable_truck:'||bt.key_id, 'money', 'warn',
         'Truck '||bt.name||' is running at a loss this week',
         'Revenue $'||bt.revenue||' vs fuel $'||bt.fuel_cost||' — net after fuel $'||bt.net_after_fuel,
         'truck', bt.key_id
    from jsonb_to_recordset(public.weekly_report()->'by_truck')
      as bt(key_id bigint, name text, revenue numeric, fuel_cost numeric, net_after_fuel numeric)
   where bt.net_after_fuel < 0;

  -- ===== CASH / AR =====
  -- Customers with balance aged past 60 days.
  insert into _findings
  select 'ar_overdue:'||a.customer_id, 'cash',
         case when a.d90_plus > 0 then 'critical' else 'warn' end,
         a.company_name||' is overdue',
         '$'||(a.d61_90 + a.d90_plus)||' past 60 days'||coalesce(' ($'||nullif(a.d90_plus,0)||' past 90)',''),
         'customer', a.customer_id
    from public.ar_aging() a
   where (a.d61_90 + a.d90_plus) > 0;

  -- Completed loads not invoiced after 7 days (revenue sitting unbilled).
  insert into _findings
  select 'uninvoiced:'||l.id, 'cash', 'warn',
         'Load '||l.load_number||' delivered but not invoiced',
         'Completed '||to_char(l.delivery_time,'Mon DD')||', $'||l.rate||' not yet on an invoice',
         'load', l.id
    from public.loads l
   where l.status = 'completed' and l.invoice_id is null
     and l.delivery_time < now() - interval '7 days';

  -- ===== OPS RISK =====
  -- Loads past their delivery time but not delivered.
  insert into _findings
  select 'late_load:'||l.id, 'ops',
         case when l.delivery_time < now() - interval '12 hours' then 'critical' else 'warn' end,
         'Load '||l.load_number||' is late',
         'Delivery was due '||to_char(l.delivery_time,'Mon DD HH24:MI')||' — still '||l.status,
         'load', l.id
    from public.loads l
   where l.status in ('assigned','in_transit') and l.delivery_time < now();

  -- On-duty drivers not reporting GPS in 30 min.
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
  -- Driver licenses expiring within 30 days (or expired).
  insert into _findings
  select 'license_exp:'||d.id, 'compliance',
         case when d.license_expiration < now()::date then 'critical' else 'warn' end,
         'License '||case when d.license_expiration < now()::date then 'EXPIRED' else 'expiring' end||' — '||d.full_name,
         'CDL expires '||to_char(d.license_expiration,'Mon DD, YYYY'),
         'driver', d.id
    from public.drivers d
   where d.status = 'active' and d.license_expiration is not null
     and d.license_expiration < now()::date + 30;

  -- Truck plates expiring within 30 days (or expired).
  insert into _findings
  select 'plate_exp:'||t.id, 'compliance',
         case when t.plate_expiry < now()::date then 'critical' else 'warn' end,
         'Registration '||case when t.plate_expiry < now()::date then 'EXPIRED' else 'expiring' end||' — truck '||t.unit_number,
         'Plate '||coalesce(nullif(t.plate_number,''),'?')||' expires '||to_char(t.plate_expiry,'Mon DD, YYYY'),
         'truck', t.id
    from public.trucks t
   where t.status <> 'retired' and t.plate_expiry is not null
     and t.plate_expiry < now()::date + 30;

  -- ===== upsert + auto-resolve =====
  insert into public.trux_insights (dedup_key, category, severity, title, detail, entity_type, entity_id)
  select dedup_key, category, severity, title, detail, entity_type, entity_id from _findings
  on conflict (dedup_key) do update set
    severity = excluded.severity, title = excluded.title, detail = excluded.detail,
    last_seen = now(),
    status = case when public.trux_insights.status = 'resolved' then 'open' else public.trux_insights.status end,
    resolved_at = case when public.trux_insights.status = 'resolved' then null else public.trux_insights.resolved_at end;
  get diagnostics fired = row_count;

  update public.trux_insights set status = 'resolved', resolved_at = now()
   where status <> 'resolved' and dedup_key not in (select dedup_key from _findings);
  get diagnostics resolved = row_count;

  return jsonb_build_object(
    'fired', fired, 'resolved', resolved,
    'open', (select count(*) from public.trux_insights where status <> 'resolved'),
    'critical', (select count(*) from public.trux_insights where status <> 'resolved' and severity = 'critical')
  );
end;
$$;

revoke execute on function public.sentinel_scan() from public, anon;
grant execute on function public.sentinel_scan() to authenticated, service_role;
grant select, insert, update on public.trux_insights to service_role;

-- ---------- feed + acknowledge (for the in-app Trux feed) ----------
create or replace function public.trux_insights_feed(p_include_resolved boolean default false)
returns setof public.trux_insights
language sql stable security definer set search_path = public
as $$
  select * from public.trux_insights
   where public.my_role() in ('admin','accountant','dispatcher')
     and (p_include_resolved or status <> 'resolved')
   order by (status = 'open') desc,
            case severity when 'critical' then 0 when 'warn' then 1 else 2 end,
            last_seen desc
   limit 200;
$$;

create or replace function public.acknowledge_insight(p_id bigint)
returns public.trux_insights
language plpgsql security definer set search_path = public
as $$
  declare row public.trux_insights;
begin
  if public.my_role() not in ('admin','accountant','dispatcher') then
    raise exception 'Not enough permissions';
  end if;
  update public.trux_insights
     set status = 'acknowledged', acknowledged_by = auth.uid(), acknowledged_at = now()
   where id = p_id and status = 'open'
   returning * into row;
  return row;
end;
$$;

revoke execute on function public.trux_insights_feed(boolean) from public, anon;
revoke execute on function public.acknowledge_insight(bigint) from public, anon;
grant execute on function public.trux_insights_feed(boolean) to authenticated;
grant execute on function public.acknowledge_insight(bigint) to authenticated;
