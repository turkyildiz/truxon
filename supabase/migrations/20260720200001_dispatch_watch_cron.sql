-- Trux dispatch shadow: poll dispatch@ every 20 minutes to keep the observation
-- ledger current. Observe-only (reads mail, logs what Trux WOULD do, executes
-- nothing). Same anon-bearer cron pattern as the other jobs.

do $$ begin perform cron.unschedule('truxon-dispatch-watch'); exception when others then null; end $$;

select cron.schedule(
  'truxon-dispatch-watch',
  '*/20 * * * *',
  $$
  select net.http_post(
    url := 'https://okoeeyxxvzypjiumraxq.supabase.co/functions/v1/dispatch-watch',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9rb2VleXh4dnp5cGppdW1yYXhxIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODQxMzc1MDAsImV4cCI6MjA5OTcxMzUwMH0.rNGfTvCQ0ggsCSc1DbbD_Tr_h3p_hoJn2q0_ev6AO3E'
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 280000
  );
  $$
);
