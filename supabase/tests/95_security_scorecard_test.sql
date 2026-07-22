-- security_scorecard() surfaces the now-computable Technology playbook metrics,
-- and is gated to finance/admin roles.
begin;
create extension if not exists pgtap with schema extensions;
select plan(5);

insert into auth.users (id, email) values
  ('00000000-0000-4000-8000-00000000595c'::uuid, 'sec-admin@test.local'),
  ('00000000-0000-4000-8000-00000000595d'::uuid, 'sec-driver@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-00000000595c';
update public.profiles set role = 'driver' where id = '00000000-0000-4000-8000-00000000595d';

select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-00000000595c"}', true);
select ok((public.security_scorecard() ? 'mfa_coverage_pct'), 'scorecard returns mfa_coverage_pct');
select ok(((public.security_scorecard()->>'audit_chain_intact')::boolean), 'audit chain reports intact');
select ok(((public.security_scorecard()->>'ransomware_guard_armed')::boolean), 'ransomware guard reports armed');

-- driver is refused
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-00000000595d"}', true);
select throws_ok('select public.security_scorecard()', 'P0001', 'Not enough permissions',
  'security_scorecard gated away from drivers');

-- the six playbook rows are now live
select is(
  (select count(*)::int from public.playbook_metrics
     where number in (902, 906, 911, 913, 916, 929) and status = 'live'),
  6, 'six Technology metrics flipped live');

select * from finish();
rollback;
