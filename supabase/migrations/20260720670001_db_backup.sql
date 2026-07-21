-- R12 #8 — off-site nightly backup: private db-backups bucket + 03:37 cron.
-- The db-backup edge function dumps the critical tables as gzipped JSON per
-- day, 30-day retention. Independent of the NAS pipeline. No storage policies:
-- only service_role touches the bucket.
insert into storage.buckets (id, name, public)
values ('db-backups', 'db-backups', false)
on conflict (id) do nothing;

do $$ begin perform cron.unschedule('truxon-db-backup'); exception when others then null; end $$;
select cron.schedule('truxon-db-backup', '37 3 * * *',
  $job$select app_private.cron_edge_call('db-backup', '{}'::jsonb)$job$);
