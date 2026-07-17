-- Trux email door: processed-message log (idempotency + audit), poll
-- throttle state, and the cron schedule that triggers inbox polling.
-- One row per Microsoft Graph message id; the unique constraint is the guard
-- against double-processing when polls overlap.

create table if not exists public.trux_inbox_log (
  id bigint generated always as identity primary key,
  graph_message_id text not null unique,
  graph_conversation_id text,
  from_email text not null,
  subject text,
  status text not null check (status in ('processing', 'processed', 'rejected', 'failed')),
  detail text,
  session_id uuid references public.trux_sessions(id),
  created_at timestamptz not null default now()
);

alter table public.trux_inbox_log enable row level security;

drop policy if exists trux_inbox_admin on public.trux_inbox_log;
create policy trux_inbox_admin on public.trux_inbox_log
  for select to authenticated
  using (public.my_role() = 'admin');

-- Single-row throttle: the poll endpoint is unauthenticated (cron-invoked),
-- so an atomic claim on this row limits it to one real poll per 30s no
-- matter how often it is hit.
create table if not exists public.trux_inbox_state (
  id int primary key default 1 check (id = 1),
  last_poll timestamptz not null default 'epoch'
);
insert into public.trux_inbox_state (id) values (1) on conflict do nothing;
alter table public.trux_inbox_state enable row level security;
-- no policies: service role only

-- Poll every 2 minutes. The function exits immediately (200, skipped) until
-- the MSGRAPH_* secrets are configured, so this is safe to schedule now.
create extension if not exists pg_cron;
create extension if not exists pg_net;

do $$
begin
  perform cron.unschedule('trux-inbox-poll');
exception when others then
  null; -- not scheduled yet
end $$;

select cron.schedule(
  'trux-inbox-poll',
  '*/2 * * * *',
  $$
  select net.http_post(
    url := 'https://okoeeyxxvzypjiumraxq.supabase.co/functions/v1/trux-inbox',
    headers := '{"Content-Type": "application/json"}'::jsonb,
    body := '{}'::jsonb,
    timeout_milliseconds := 60000
  );
  $$
);
