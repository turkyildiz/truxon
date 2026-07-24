-- READINESS #192: security-posture baseline. bless_security_baseline() is the
-- anchor for posture-drift detection — it snapshots the current known-good
-- security posture (grants, policies, definer flags via app_private.security_posture())
-- into app_private.security_baseline, and the posture-drift sentinel later fires
-- on anything that appears/disappears vs that snapshot. Two guarantees: only an
-- admin (or service_role) may re-bless the baseline (it defines "known-good", so
-- it's a privileged act), and a bless actually captures current posture — after
-- it, there is zero drift.
begin;
create extension if not exists pgtap with schema extensions;
select plan(4);

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-4000-8000-0000000bb101'::uuid, 'bl-admin@test.local', '{}'::jsonb),
  ('00000000-0000-4000-8000-0000000bb103'::uuid, 'bl-drv@test.local',   '{"role":"driver"}'::jsonb);
update public.profiles set role='admin' where id='00000000-0000-4000-8000-0000000bb101';

-- ═══ re-blessing the baseline is admin-only ═══
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000bb103"}', true);
select throws_ok($$select public.bless_security_baseline()$$,
  'Not enough permissions', '1. a driver cannot re-bless the security baseline');

-- ═══ a bless captures current posture (drift → 0) ═══
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000bb101"}', true);
-- introduce one unit of drift: an item present in live posture but missing from the baseline
delete from app_private.security_baseline
 where ctid = (select ctid from app_private.security_baseline limit 1);
select cmp_ok((public.bless_security_baseline()->>'newly_added')::int, '>=', 1,
  '2. blessing re-captures posture items that had drifted out of the baseline');

-- an immediate second bless sees no drift — the baseline is now current
select is((public.bless_security_baseline()->>'newly_added')::int, 0,
  '3. after a bless there is zero remaining drift');
select is((public.bless_security_baseline()->>'blessed')::boolean, true,
  '4. bless reports success');

select * from finish();
rollback;
