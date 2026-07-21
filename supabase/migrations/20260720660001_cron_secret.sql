-- R12 #7b — S-01 remediation: cron jobs authenticate with a real secret.
-- The public anon JWT is no longer authorization for privileged edge doors
-- (every job function now checks the x-cron-key header against CRON_SECRET).
-- The DB-side copy of the secret lives in app_private.cron_config — set at
-- deploy time through the watchdog's admin-gated set_cron_secret mode, NEVER
-- committed to git. cron_edge_call() centralizes the outbound call.

create schema if not exists app_private;
create table if not exists app_private.cron_config (
  key text primary key,
  value text not null,
  updated_at timestamptz not null default now()
);
grant usage on schema app_private to service_role;
grant select, insert, update on app_private.cron_config to service_role;

create or replace function public.set_cron_config(p_key text, p_value text)
returns void
language sql security invoker
as $fn$
  insert into app_private.cron_config as c (key, value) values (p_key, p_value)
  on conflict (key) do update set value = excluded.value, updated_at = now();
$fn$;
revoke all on function public.set_cron_config(text, text) from public, anon, authenticated;
grant execute on function public.set_cron_config(text, text) to service_role;

create or replace function app_private.cron_edge_call(p_fn text, p_body jsonb default '{}'::jsonb)
returns bigint
language sql
security definer
set search_path = public, app_private
as $fn$
  select net.http_post(
    url := 'https://okoeeyxxvzypjiumraxq.supabase.co/functions/v1/' || p_fn,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9rb2VleXh4dnp5cGppdW1yYXhxIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODQxMzc1MDAsImV4cCI6MjA5OTcxMzUwMH0.rNGfTvCQ0ggsCSc1DbbD_Tr_h3p_hoJn2q0_ev6AO3E',
      'x-cron-key', coalesce((select value from app_private.cron_config where key = 'cron_secret'), '')),
    body := p_body);
$fn$;
revoke all on function app_private.cron_edge_call(text, jsonb) from public, anon, authenticated;


do $$ begin perform cron.unschedule('trux-inbox-poll'); exception when others then null; end $$;
select cron.schedule('trux-inbox-poll', '*/2 * * * *',
  $job$select app_private.cron_edge_call('trux-inbox', '{}'::jsonb)$job$);

do $$ begin perform cron.unschedule('trux-sentinel-scan'); exception when others then null; end $$;
select cron.schedule('trux-sentinel-scan', '*/15 * * * *',
  $job$select app_private.cron_edge_call('trux-sentinel', '{"mode":"scan"}'::jsonb)$job$);

do $$ begin perform cron.unschedule('trux-sentinel-brief'); exception when others then null; end $$;
select cron.schedule('trux-sentinel-brief', '0 13 * * *',
  $job$select app_private.cron_edge_call('trux-sentinel', '{"mode":"brief"}'::jsonb)$job$);

do $$ begin perform cron.unschedule('truxon-customer-enrich-monthly'); exception when others then null; end $$;
select cron.schedule('truxon-customer-enrich-monthly', '0 4 1 * *',
  $job$select app_private.cron_edge_call('customer-enrich', '{"cron":true}'::jsonb)$job$);

do $$ begin perform cron.unschedule('truxon-dispatch-mine'); exception when others then null; end $$;
select cron.schedule('truxon-dispatch-mine', '37 */2 * * *',
  $job$select app_private.cron_edge_call('dispatch-watch', '{"mode":"mine"}'::jsonb)$job$);

do $$ begin perform cron.unschedule('truxon-dispatch-watch'); exception when others then null; end $$;
select cron.schedule('truxon-dispatch-watch', '*/20 * * * *',
  $job$select app_private.cron_edge_call('dispatch-watch', '{}'::jsonb)$job$);

do $$ begin perform cron.unschedule('truxon-eld-history'); exception when others then null; end $$;
select cron.schedule('truxon-eld-history', '32 5 * * *',
  $job$select app_private.cron_edge_call('eld-sync', '{"mode":"history","days":2}'::jsonb)$job$);

do $$ begin perform cron.unschedule('truxon-eld-sync'); exception when others then null; end $$;
select cron.schedule('truxon-eld-sync', '*/15 * * * *',
  $job$select app_private.cron_edge_call('eld-sync', '{}'::jsonb)$job$);

do $$ begin perform cron.unschedule('truxon-fmcsa-watch'); exception when others then null; end $$;
select cron.schedule('truxon-fmcsa-watch', '17 6 * * 1',
  $job$select app_private.cron_edge_call('fmcsa-watch', '{}'::jsonb)$job$);

do $$ begin perform cron.unschedule('truxon-geocode-backfill'); exception when others then null; end $$;
select cron.schedule('truxon-geocode-backfill', '17 * * * *',
  $job$select app_private.cron_edge_call('geocode', '{"mode":"backfill","limit":60}'::jsonb)$job$);

do $$ begin perform cron.unschedule('truxon-qbo-customers-monthly'); exception when others then null; end $$;
select cron.schedule('truxon-qbo-customers-monthly', '30 4 1 * *',
  $job$select app_private.cron_edge_call('qbo-sync', '{"mode":"customers"}'::jsonb)$job$);

do $$ begin perform cron.unschedule('truxon-qbo-pull'); exception when others then null; end $$;
select cron.schedule('truxon-qbo-pull', '*/30 * * * *',
  $job$select app_private.cron_edge_call('qbo-sync', '{"mode":"pull"}'::jsonb)$job$);

do $$ begin perform cron.unschedule('truxon-watchdog'); exception when others then null; end $$;
select cron.schedule('truxon-watchdog', '*/5 * * * *',
  $job$select app_private.cron_edge_call('watchdog', '{}'::jsonb)$job$);
