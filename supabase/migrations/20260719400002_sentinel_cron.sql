-- Schedule the Sentinel: a scan every 15 minutes (pushes new criticals) and a
-- daily brief at 13:00 UTC (~07:00 Central America). Like trux-inbox, the cron
-- authenticates with the public anon key; the function does its work under the
-- service role. trux-sentinel stays behind the platform JWT gate (no config
-- block → verify_jwt defaults on).

do $$ begin perform cron.unschedule('trux-sentinel-scan'); exception when others then null; end $$;
do $$ begin perform cron.unschedule('trux-sentinel-brief'); exception when others then null; end $$;

select cron.schedule(
  'trux-sentinel-scan',
  '*/15 * * * *',
  $$
  select net.http_post(
    url := 'https://okoeeyxxvzypjiumraxq.supabase.co/functions/v1/trux-sentinel',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9rb2VleXh4dnp5cGppdW1yYXhxIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODQxMzc1MDAsImV4cCI6MjA5OTcxMzUwMH0.rNGfTvCQ0ggsCSc1DbbD_Tr_h3p_hoJn2q0_ev6AO3E'
    ),
    body := '{"mode":"scan"}'::jsonb,
    timeout_milliseconds := 60000
  );
  $$
);

select cron.schedule(
  'trux-sentinel-brief',
  '0 13 * * *',
  $$
  select net.http_post(
    url := 'https://okoeeyxxvzypjiumraxq.supabase.co/functions/v1/trux-sentinel',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9rb2VleXh4dnp5cGppdW1yYXhxIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODQxMzc1MDAsImV4cCI6MjA5OTcxMzUwMH0.rNGfTvCQ0ggsCSc1DbbD_Tr_h3p_hoJn2q0_ev6AO3E'
    ),
    body := '{"mode":"brief"}'::jsonb,
    timeout_milliseconds := 60000
  );
  $$
);
