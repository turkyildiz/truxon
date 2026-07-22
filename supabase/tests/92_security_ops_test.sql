-- Security operations batch: tamper-evident audit log, role-escalation
-- tripwire, honeytoken replay, posture-drift detection, and break-glass.
begin;
create extension if not exists pgtap with schema extensions;
select plan(14);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000f92'::uuid, 'sec@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000f92';
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-8000-000000000f92","role":"authenticated","email":"sec@test.local"}', true);

-- ---- audit log: append-only + hash chain ----
select public.security_audit_verify();  -- warm
select ok((select (public.security_audit_verify()->>'intact')::boolean),
  'audit chain is intact at start');
select throws_ok('delete from app_private.security_audit',
  'security_audit is append-only (attempted DELETE)', 'audit rows cannot be deleted');
select throws_ok($$update app_private.security_audit set severity='info'$$,
  'security_audit is append-only (attempted UPDATE)', 'audit rows cannot be updated');

-- ---- role-escalation tripwire ----
insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000f93'::uuid, 'victim@test.local');
update public.profiles set role = 'dispatcher' where id = '00000000-0000-4000-8000-000000000f93';
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000f93';
select ok(exists(select 1 from app_private.security_audit
                  where event_type='admin_granted' and severity='critical'
                    and (detail->>'target')='00000000-0000-4000-8000-000000000f93'),
  'elevation to admin writes a critical audit row');
select public.sentinel_scan();  -- the finding is produced from the audit log
select ok(exists(select 1 from public.trux_insights
                  where dedup_key like 'admin_granted:%' and severity='critical'),
  'elevation to admin raises a critical Forest finding');
select ok((select (public.security_audit_verify()->>'intact')::boolean),
  'audit chain still intact after several events');

-- a tamper breaks the chain (simulate a superuser edit, then verify detects it)
set session_replication_role = replica;  -- bypass the immutability trigger, like a superuser would
update app_private.security_audit set detail = '{"tampered":true}'::jsonb
 where id = (select min(id) from app_private.security_audit);
set session_replication_role = origin;
select ok(not (public.security_audit_verify()->>'intact')::boolean,
  'verify() detects tampering (chain broken)');

-- ---- honeytokens (salting) ----
-- sha256 of the decoy denim key (plaintext deliberately not in the repo)
select ok(public.honeytoken_seen('1ec2a4a718039d269540386691250abfe8a21e52ef718a715ecec0e91ac42eb5'),
  'a replayed decoy key is recognized as a honeytoken');
select ok(not public.honeytoken_seen(encode(extensions.digest('a-real-looking-but-unknown-key','sha256'),'hex')),
  'an unknown secret is not a honeytoken');
select ok(exists(select 1 from public.trux_insights
                  where dedup_key like 'honeytoken:%' and severity='critical'),
  'honeytoken replay raises a critical finding');

-- ---- canary account is dormant ----
select ok((select not is_active from public.profiles where id='00000000-0000-4000-8000-00000000ca11'),
  'canary account exists and is permanently inactive');

-- ---- posture drift ----
select is((select count(*)::int from (
             select kind,item from app_private.security_posture()
             except select kind,item from app_private.security_baseline) d),
          0, 'no posture drift at baseline');
create table public._drift_probe (id int);
grant select on public._drift_probe to anon;   -- introduce drift
select ok((select count(*) from (
             select kind,item from app_private.security_posture()
             except select kind,item from app_private.security_baseline) d) > 0,
  'a new anon grant shows up as drift vs baseline');
drop table public._drift_probe;

-- ---- break-glass ----
select public.set_lockdown(true, 'test');
select throws_like($$update public.profiles set role='dispatcher' where id='00000000-0000-4000-8000-000000000f93'$$,
  '%lockdown%', 'lockdown freezes role changes');
select public.set_lockdown(false, 'test done');

select * from finish();
rollback;
