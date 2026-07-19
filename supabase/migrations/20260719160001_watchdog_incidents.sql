-- Watchdog v2: incident history + a remediation ledger that is the ONLY record
-- of anything the self-heal engine does. Every automatic or approved action
-- writes a row here with before/after snapshots, so a human can always see —
-- and undo — what the system did. The registry of *what* may be done lives in
-- code (watchdog edge function); this table records that it happened and gates
-- rate limits + one-tap approvals.

-- One row per open→resolved failure episode of a check (flap-suppressed:
-- re-failing a still-open incident does not open a new one).
create table if not exists public.watchdog_incidents (
  id bigint generated always as identity primary key,
  check_name text not null,
  severity text not null default 'warn' check (severity in ('info', 'warn', 'critical')),
  status text not null default 'open' check (status in ('open', 'resolved')),
  detail text not null default '',
  opened_at timestamptz not null default now(),
  resolved_at timestamptz,
  remediation_count int not null default 0,
  updated_at timestamptz not null default now()
);

create index if not exists watchdog_incidents_open_idx
  on public.watchdog_incidents (check_name) where status = 'open';
create index if not exists watchdog_incidents_opened_idx
  on public.watchdog_incidents (opened_at desc);

-- The ledger. action_key names a code-defined remediation from the registry;
-- params/before_state/after_state are snapshots; tier records how it was
-- authorized. A 'proposed' row carries an approval_token + expiry and does
-- nothing until approved. revert_of points a rollback at what it undid.
create table if not exists public.watchdog_remediations (
  id bigint generated always as identity primary key,
  incident_id bigint references public.watchdog_incidents (id) on delete set null,
  check_name text not null,
  action_key text not null,
  tier text not null check (tier in ('auto', 'approval')),
  status text not null default 'proposed'
    check (status in ('proposed', 'applied', 'verified', 'failed', 'reverted', 'expired', 'rejected')),
  params jsonb not null default '{}',
  before_state jsonb,
  after_state jsonb,
  detail text not null default '',
  revert_of bigint references public.watchdog_remediations (id),
  approval_token text unique,
  proposed_at timestamptz not null default now(),
  decided_at timestamptz,
  expires_at timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists watchdog_remediations_recent_idx
  on public.watchdog_remediations (action_key, created_at desc);
create index if not exists watchdog_remediations_incident_idx
  on public.watchdog_remediations (incident_id);
create index if not exists watchdog_remediations_pending_idx
  on public.watchdog_remediations (status) where status = 'proposed';

alter table public.watchdog_incidents enable row level security;
alter table public.watchdog_remediations enable row level security;

-- Admins can read the history in-app; ALL writes go through the service role
-- in the watchdog function (no policy = no client write path, even for admins).
drop policy if exists watchdog_incidents_admin_read on public.watchdog_incidents;
create policy watchdog_incidents_admin_read on public.watchdog_incidents
  for select to authenticated using (public.my_role() = 'admin');

drop policy if exists watchdog_remediations_admin_read on public.watchdog_remediations;
create policy watchdog_remediations_admin_read on public.watchdog_remediations
  for select to authenticated using (public.my_role() = 'admin');

-- How many times an action ran (applied/verified/reverted count as "ran")
-- within the trailing window — the code-side rate limiter reads this so a
-- flapping check can't drive an action in a loop.
create or replace function public.watchdog_action_count(p_action_key text, p_since_minutes int)
returns int
language sql stable security definer set search_path = public
as $$
  select count(*)::int
    from public.watchdog_remediations
   where action_key = p_action_key
     and status in ('applied', 'verified', 'reverted', 'failed')
     and created_at > now() - make_interval(mins => p_since_minutes);
$$;

revoke execute on function public.watchdog_action_count(text, int) from public, anon;

-- Admins can list open incidents in-app (SECURITY DEFINER so the panel needs
-- no direct table grants beyond the read policy above).
create or replace function public.watchdog_incident_feed(p_limit int default 50)
returns setof public.watchdog_incidents
language sql stable security definer set search_path = public
as $$
  select * from public.watchdog_incidents
   where public.my_role() = 'admin'
   order by (status = 'open') desc, opened_at desc
   limit greatest(1, least(p_limit, 200));
$$;

revoke execute on function public.watchdog_incident_feed(int) from public, anon;
grant execute on function public.watchdog_incident_feed(int) to authenticated;

-- External heartbeats (e.g. the NAS backup job pings "I ran"): the watchdog
-- alarms when a heartbeat goes stale. Written only via the report-key-gated
-- heartbeat mode of the watchdog function (service role); no client policy.
create table if not exists public.watchdog_heartbeats (
  source text primary key,
  last_seen timestamptz not null default now(),
  detail text not null default ''
);
alter table public.watchdog_heartbeats enable row level security;

drop policy if exists watchdog_heartbeats_admin_read on public.watchdog_heartbeats;
create policy watchdog_heartbeats_admin_read on public.watchdog_heartbeats
  for select to authenticated using (public.my_role() = 'admin');

-- One round trip for the DB-heavy business checks. SECURITY DEFINER so the
-- watchdog's service role reads across tables; returns everything the edge
-- function turns into pass/fail CheckResults.
create or replace function public.watchdog_db_probes(p_gps_stale_min int default 15, p_backup_stale_hours int default 26)
returns jsonb
language sql stable security definer set search_path = public, cron
as $$
  select jsonb_build_object(
    -- GPS: on-duty drivers whose latest fix is missing or older than the window.
    'gps_on_duty', (select count(*)::int from public.driver_duty where is_on_duty),
    'gps_stale', (
      select count(*)::int from public.driver_duty dd
       where dd.is_on_duty
         and not exists (
           select 1 from public.vehicle_position_current vpc
            where vpc.driver_id = dd.driver_id
              and vpc.recorded_at > now() - make_interval(mins => p_gps_stale_min))),
    -- Invoice numbering integrity canaries.
    'invoice_dupes', (
      select count(*)::int from (
        select invoice_number from public.invoices
         where status <> 'void' group by invoice_number having count(*) > 1) d),
    'invoice_seq_behind', (
      select coalesce(
        (select last_value from public.invoice_number_seq)
          < (select coalesce(max((regexp_match(invoice_number, '^INV-\d{4}-(\d+)$'))[1]::bigint), 0)
               from public.invoices), false)),
    -- Inbox rows wedged mid-processing beyond a poll cycle.
    'stuck_processing', (
      select count(*)::int from public.trux_inbox_log
       where status = 'processing' and created_at < now() - interval '15 minutes'),
    -- Backup heartbeat freshness.
    'backup_stale', (
      select coalesce(
        (select last_seen from public.watchdog_heartbeats where source = 'backup')
          < now() - make_interval(hours => p_backup_stale_hours),
        true)),
    'backup_last_seen', (select last_seen from public.watchdog_heartbeats where source = 'backup')
  );
$$;

revoke execute on function public.watchdog_db_probes(int, int) from public, anon;

-- The watchdog edge function runs as service_role. Grant exactly what it needs:
-- execute on the probe/count helpers (the PUBLIC default was revoked above) and
-- DML on the ledger tables. In hosted Supabase service_role already holds these
-- (it bypasses RLS with full public access); these statements make a fresh
-- local/CI database match prod so the engine is testable end to end.
grant execute on function public.watchdog_db_probes(int, int) to service_role;
grant execute on function public.watchdog_action_count(text, int) to service_role;
grant select, insert, update, delete
  on public.watchdog_incidents, public.watchdog_remediations, public.watchdog_heartbeats
  to service_role;

-- The watchdog's complete write surface, stated explicitly (in hosted Supabase
-- service_role already has these; the grants make local/CI faithful AND
-- document exactly which tables the self-heal engine may touch — its writes
-- go nowhere else):
--   watchdog_state       health-check state upserts
--   trux_inbox_state     reset_inbox_poll_throttle remediation
--   trux_inbox_log       requeue_stuck_processing remediation + inbox retries
--   companion_config     disable_agent_load_shed remediation
grant select, insert, update on public.watchdog_state to service_role;
grant select, update on public.trux_inbox_state, public.trux_inbox_log, public.companion_config to service_role;
grant select on public.profiles, public.driver_duty, public.vehicle_position_current, public.invoices to service_role;
