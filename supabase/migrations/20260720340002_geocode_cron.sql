-- Geocode backfill schedule. Works through ungeocoded loads a bounded batch at a
-- time (cache-first, so repeated shippers are free), then idles once caught up —
-- only new loads remain to do. Hourly keeps Google usage gentle. Same anon-bearer
-- cron pattern as the other jobs.

do $$ begin perform cron.unschedule('truxon-geocode-backfill'); exception when others then null; end $$;

select cron.schedule(
  'truxon-geocode-backfill',
  '17 * * * *',   -- hourly at :17, one batch of ungeocoded loads
  $$
  select net.http_post(
    url := 'https://okoeeyxxvzypjiumraxq.supabase.co/functions/v1/geocode',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9rb2VleXh4dnp5cGppdW1yYXhxIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODQxMzc1MDAsImV4cCI6MjA5OTcxMzUwMH0.rNGfTvCQ0ggsCSc1DbbD_Tr_h3p_hoJn2q0_ev6AO3E'
    ),
    body := '{"mode":"backfill","limit":60}'::jsonb,
    timeout_milliseconds := 280000
  );
  $$
);
