-- trux-inbox stays behind the platform JWT gate (no --no-verify-jwt); the
-- cron poll authenticates with the anon key, which is public by design —
-- real authorization is the sender verification inside the function.

do $$
begin
  perform cron.unschedule('trux-inbox-poll');
exception when others then
  null;
end $$;

select cron.schedule(
  'trux-inbox-poll',
  '*/2 * * * *',
  $$
  select net.http_post(
    url := 'https://okoeeyxxvzypjiumraxq.supabase.co/functions/v1/trux-inbox',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9rb2VleXh4dnp5cGppdW1yYXhxIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODQxMzc1MDAsImV4cCI6MjA5OTcxMzUwMH0.rNGfTvCQ0ggsCSc1DbbD_Tr_h3p_hoJn2q0_ev6AO3E'
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 60000
  );
  $$
);
