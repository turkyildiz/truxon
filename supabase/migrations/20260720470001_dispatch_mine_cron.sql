-- Dispatch miner (owner directive 2026-07-20: "find missing pods, paperworks
-- and customer data and filling them in"): every 2 hours, search dispatch@ for
-- paperwork matching loads missing a POD (verbatim ref match required) and fill
-- BLANK customer contact fields from already-observed broker emails. Files
-- documents + fills fields only — never sends, never changes read state, never
-- touches load status. Every action lands in the shadow ledger for review.

do $$ begin perform cron.unschedule('truxon-dispatch-mine'); exception when others then null; end $$;

select cron.schedule(
  'truxon-dispatch-mine',
  '37 */2 * * *',
  $$
  select net.http_post(
    url := 'https://okoeeyxxvzypjiumraxq.supabase.co/functions/v1/dispatch-watch',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9rb2VleXh4dnp5cGppdW1yYXhxIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODQxMzc1MDAsImV4cCI6MjA5OTcxMzUwMH0.rNGfTvCQ0ggsCSc1DbbD_Tr_h3p_hoJn2q0_ev6AO3E'
    ),
    body := '{"mode":"mine"}'::jsonb,
    timeout_milliseconds := 280000
  );
  $$
);
