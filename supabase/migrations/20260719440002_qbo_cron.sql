-- Pull QBO invoice changes every 30 minutes. Like the sentinel cron, the call
-- authenticates with the public anon key; qbo-sync recognizes that bearer as
-- the cron caller and does its work under the service role. Harmless before
-- the QBO connection exists (pull returns 409 until connected).

do $$ begin perform cron.unschedule('truxon-qbo-pull'); exception when others then null; end $$;

select cron.schedule(
  'truxon-qbo-pull',
  '*/30 * * * *',
  $$
  select net.http_post(
    url := 'https://okoeeyxxvzypjiumraxq.supabase.co/functions/v1/qbo-sync',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9rb2VleXh4dnp5cGppdW1yYXhxIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODQxMzc1MDAsImV4cCI6MjA5OTcxMzUwMH0.rNGfTvCQ0ggsCSc1DbbD_Tr_h3p_hoJn2q0_ev6AO3E'
    ),
    body := '{"mode":"pull"}'::jsonb,
    timeout_milliseconds := 120000
  );
  $$
);
