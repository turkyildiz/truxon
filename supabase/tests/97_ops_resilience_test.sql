-- Ops-resilience sentinel checks (20260722008002): off-site backup freshness
-- fires on an empty/stale db-backups bucket and resolves on a fresh object;
-- the zero-MFA nudge stands until any office user verifies a factor.
begin;
create extension if not exists pgtap with schema extensions;
select plan(5);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000970'::uuid, 'ops@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000970';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000970"}', true);

-- the migration-seeded bucket exists with no objects → "NEVER" fires
select ok((select public.sentinel_scan() is not null), 'scan runs');
select ok(
  exists(select 1 from public.trux_insights
          where dedup_key = 'backup_bucket_stale' and status = 'open' and detail like '%NEVER%'),
  'empty backup bucket fires the stale-backup critical');
select ok(
  exists(select 1 from public.trux_insights where dedup_key = 'mfa_coverage_zero' and status = 'open'),
  'zero office MFA enrollment fires the nudge');

-- fresh dump object → backup finding resolves
insert into storage.objects (bucket_id, name, created_at) values ('db-backups', 't.dump.gz', now());
select public.sentinel_scan();
select is(
  (select status from public.trux_insights where dedup_key = 'backup_bucket_stale'),
  'resolved', 'fresh backup object auto-resolves the finding');

-- one verified office factor → MFA nudge resolves
insert into auth.mfa_factors (id, user_id, friendly_name, factor_type, status, created_at, updated_at)
values (gen_random_uuid(), '00000000-0000-4000-8000-000000000970', 't', 'totp', 'verified', now(), now());
select public.sentinel_scan();
select is(
  (select status from public.trux_insights where dedup_key = 'mfa_coverage_zero'),
  'resolved', 'first verified office factor auto-resolves the MFA nudge');

select * from finish();
rollback;
