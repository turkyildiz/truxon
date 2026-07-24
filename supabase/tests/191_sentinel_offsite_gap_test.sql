-- READINESS: the offsite-mirror-stale sentinel fires when backups are live but
-- the offsite leg has stopped — the silent failure of 2026-07-23 — and stays
-- quiet on a fresh DB and when the mirror is fresh.
begin;
create extension if not exists pgtap with schema extensions;
select plan(4);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-0000000001a6'::uuid, 'og-admin@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-0000000001a6';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000001a6"}', true);

-- 1. fresh DB with no heartbeats at all → no alarm (dev/test quiet)
select public.sentinel_scan();
select is((select count(*) from public.trux_insights where dedup_key='offsite_mirror_stale' and status<>'resolved'), 0::bigint,
  'no backup heartbeat at all keeps the offsite check quiet');

-- 2. backups live but offsite heartbeat stale (28h) → CRITICAL fires (the incident)
insert into public.watchdog_heartbeats (source, last_seen) values
  ('backup', now() - interval '2 hours'),
  ('offsite', now() - interval '28 hours');
select public.sentinel_scan();
select is((select severity from public.trux_insights where dedup_key='offsite_mirror_stale' and status<>'resolved'),
  'critical', 'a live backup with a 28h-stale offsite mirror fires a critical finding');

-- 3. a fresh offsite mirror auto-resolves it
update public.watchdog_heartbeats set last_seen = now() where source = 'offsite';
select public.sentinel_scan();
select is((select status from public.trux_insights where dedup_key='offsite_mirror_stale'), 'resolved',
  'a fresh offsite mirror auto-resolves the finding');

-- 4. offsite MISSING entirely while backups run also fires (the never-mirrored trap)
delete from public.watchdog_heartbeats where source = 'offsite';
select public.sentinel_scan();
select is((select count(*) from public.trux_insights where dedup_key='offsite_mirror_stale' and status<>'resolved'), 1::bigint,
  'a missing offsite heartbeat while backups run also alarms (not silently OK)');

select * from finish();
rollback;
