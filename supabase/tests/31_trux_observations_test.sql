-- Trux dispatch shadow ledger: log_observation is service-only + idempotent by
-- message_id; a driver can't read the observations.
begin;
create extension if not exists pgtap with schema extensions;
select plan(6);

-- ── service writes an observation ──
select set_config('request.jwt.claims', '', true);
select isnt(public.log_observation(jsonb_build_object(
  'message_id','AAMk-1','sender_email','ops@tql.com','subject','Rate con load 5521',
  'classification','rate_con','summary','TQL rate con Chicago to Dallas',
  'would_action','create_load','would_detail','create load for TQL $2400','confidence','high'
)), null, 'observation logged');
select is((select classification from public.trux_observations where message_id='AAMk-1'), 'rate_con', 'stored classification');
select is((select would_action from public.trux_observations where message_id='AAMk-1'), 'create_load', 'stored would-action');

-- idempotent: same message_id logs once (returns null second time)
select is(public.log_observation('{"message_id":"AAMk-1","subject":"dup"}'::jsonb), null, 're-log of same message is a no-op');
select is((select count(*)::int from public.trux_observations where message_id='AAMk-1'), 1, 'no duplicate row');

-- ── gate: a driver cannot read the shadow ledger ──
insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000e31'::uuid, 'obs@test.local');
update public.profiles set role='driver' where id='00000000-0000-4000-8000-000000000e31';
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000e31","role":"authenticated"}', true);
select is((select count(*)::int from public.trux_observations), 0, 'driver sees no observations (RLS)');

reset role;
select * from finish();
rollback;
