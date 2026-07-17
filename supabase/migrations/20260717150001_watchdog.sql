-- Watchdog: health-check state (one row per check) + 5-min cron trigger.
-- Anon key in the header is public by design (ships in the frontend bundle).

create table if not exists public.watchdog_state (
  check_name text primary key,
  status text not null check (status in ('ok', 'fail')),
  detail text,
  last_change timestamptz,
  last_alert timestamptz,
  updated_at timestamptz not null default now()
);

alter table public.watchdog_state enable row level security;

drop policy if exists watchdog_admin_read on public.watchdog_state;
create policy watchdog_admin_read on public.watchdog_state
  for select to authenticated
  using (public.my_role() = 'admin');

do $$
begin
  perform cron.unschedule('truxon-watchdog');
exception when others then
  null;
end $$;

select cron.schedule(
  'truxon-watchdog',
  '*/5 * * * *',
  $$
  select net.http_post(
    url := 'https://okoeeyxxvzypjiumraxq.supabase.co/functions/v1/watchdog',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9rb2VleXh4dnp5cGppdW1yYXhxIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODQxMzc1MDAsImV4cCI6MjA5OTcxMzUwMH0.rNGfTvCQ0ggsCSc1DbbD_Tr_h3p_hoJn2q0_ev6AO3E'
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 60000
  );
  $$
);
