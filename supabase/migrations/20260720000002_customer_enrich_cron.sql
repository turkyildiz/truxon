-- Keep the Customers section fresh: once a month, Trux re-reads paperwork and
-- fills any still-blank fields (new customers added that month, or ones whose
-- documents arrived later). Like the QBO/sentinel crons, the call authenticates
-- with the public anon key; customer-enrich recognizes that bearer as the cron
-- caller and runs its maintenance sweep under the service role. Blanks-only, so
-- re-running is always safe.
--
-- Schedule: 04:00 UTC on the 1st of each month.

do $$ begin perform cron.unschedule('truxon-customer-enrich-monthly'); exception when others then null; end $$;

select cron.schedule(
  'truxon-customer-enrich-monthly',
  '0 4 1 * *',
  $$
  select net.http_post(
    url := 'https://okoeeyxxvzypjiumraxq.supabase.co/functions/v1/customer-enrich',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9rb2VleXh4dnp5cGppdW1yYXhxIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODQxMzc1MDAsImV4cCI6MjA5OTcxMzUwMH0.rNGfTvCQ0ggsCSc1DbbD_Tr_h3p_hoJn2q0_ev6AO3E'
    ),
    body := '{"cron":true}'::jsonb,
    timeout_milliseconds := 280000
  );
  $$
);
