-- ELD sync schedules: live status every 15 min, GPS breadcrumb history nightly.
-- Same anon-bearer cron pattern as the other jobs.

do $$ begin perform cron.unschedule('truxon-eld-sync'); exception when others then null; end $$;
do $$ begin perform cron.unschedule('truxon-eld-history'); exception when others then null; end $$;

select cron.schedule(
  'truxon-eld-sync',
  '*/15 * * * *',
  $$
  select net.http_post(
    url := 'https://okoeeyxxvzypjiumraxq.supabase.co/functions/v1/eld-sync',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9rb2VleXh4dnp5cGppdW1yYXhxIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODQxMzc1MDAsImV4cCI6MjA5OTcxMzUwMH0.rNGfTvCQ0ggsCSc1DbbD_Tr_h3p_hoJn2q0_ev6AO3E'
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 280000
  );
  $$
);

select cron.schedule(
  'truxon-eld-history',
  '32 5 * * *',   -- nightly 05:32, sweep the last 2 days of breadcrumbs
  $$
  select net.http_post(
    url := 'https://okoeeyxxvzypjiumraxq.supabase.co/functions/v1/eld-sync',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9rb2VleXh4dnp5cGppdW1yYXhxIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODQxMzc1MDAsImV4cCI6MjA5OTcxMzUwMH0.rNGfTvCQ0ggsCSc1DbbD_Tr_h3p_hoJn2q0_ev6AO3E'
    ),
    body := '{"mode":"history","days":2}'::jsonb,
    timeout_milliseconds := 280000
  );
  $$
);
