-- Keep customer contact/address fresh from QuickBooks monthly (structured source
-- that covers billing address / email / contact best). Pairs with the document
-- enrichment cron. Same anon-bearer cron pattern as the other QBO jobs; writes go
-- through the blanks-only apply_customer_enrichment RPC. Runs 04:30 UTC on the 1st.

do $$ begin perform cron.unschedule('truxon-qbo-customers-monthly'); exception when others then null; end $$;

select cron.schedule(
  'truxon-qbo-customers-monthly',
  '30 4 1 * *',
  $$
  select net.http_post(
    url := 'https://okoeeyxxvzypjiumraxq.supabase.co/functions/v1/qbo-sync',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9rb2VleXh4dnp5cGppdW1yYXhxIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODQxMzc1MDAsImV4cCI6MjA5OTcxMzUwMH0.rNGfTvCQ0ggsCSc1DbbD_Tr_h3p_hoJn2q0_ev6AO3E'
    ),
    body := '{"mode":"customers"}'::jsonb,
    timeout_milliseconds := 280000
  );
  $$
);
