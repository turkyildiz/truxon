-- Denim factoring sync plumbing (dark launch — the edge fn is dormant until the
-- DENIM_API_KEY secret is set). denim_job_id links an invoice to its Denim Job
-- (matched by reference_number). The 2h cron is harmless while dormant: the
-- function returns {skipped} without the key.

alter table public.invoices add column if not exists denim_job_id text;
create index if not exists invoices_denim_job_idx on public.invoices (denim_job_id) where denim_job_id is not null;

do $$ begin perform cron.unschedule('truxon-denim-sync'); exception when others then null; end $$;
select cron.schedule('truxon-denim-sync', '25 */2 * * *',
  $job$select app_private.cron_edge_call('denim-sync', '{}'::jsonb)$job$);
