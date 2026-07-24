-- R9 #165: real-user timing — users insert only their own samples, only
-- admins read the report, percentiles come back sane, and the metric check
-- rejects junk.
begin;
create extension if not exists pgtap with schema extensions;
select plan(6);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000185'::uuid, 'wv-admin@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000185';
insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000186'::uuid, 'wv-disp@test.local');
update public.profiles set role = 'dispatcher' where id = '00000000-0000-4000-8000-000000000186';

-- samples land as the reporting user (RLS: user_id = auth.uid())
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000186"}', true);
insert into public.web_vitals (session_id, user_id, path, metric, value) values
  ('s1', '00000000-0000-4000-8000-000000000186', '/loads', 'lcp', 1200),
  ('s1', '00000000-0000-4000-8000-000000000186', '/loads', 'lcp', 1800),
  ('s1', '00000000-0000-4000-8000-000000000186', '/loads', 'lcp', 2400),
  ('s1', '00000000-0000-4000-8000-000000000186', '/loads', 'ttfb', 300),
  ('s1', '00000000-0000-4000-8000-000000000186', '', 'session_s', 600);

-- 1. can't forge another user's sample
select throws_like($$
  insert into public.web_vitals (session_id, user_id, path, metric, value)
  values ('s2', '00000000-0000-4000-8000-000000000185', '/x', 'lcp', 1)
$$, '%row-level security%', 'a user cannot insert a sample as someone else');

-- 2. metric check rejects junk
select throws_like($$
  insert into public.web_vitals (session_id, path, metric, value) values ('s1', '/x', 'bogus', 1)
$$, '%web_vitals_metric_check%', 'unknown metric is rejected');

-- 3. dispatcher cannot read the report (admin-only)
select throws_ok($$ select public.web_perf_report(7) $$,
  'Not enough permissions', 'non-admin is refused the report');
reset role;

-- 4-6. admin gets sane aggregates
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000185"}', true);
select is((select (public.web_perf_report(7)->>'sessions')::int), 1, 'one distinct session counted');
select is((select public.web_perf_report(7)->'metrics'->'lcp'->>'p50'), '1800',
  'LCP p50 is the middle sample');
select is((select (public.web_perf_report(7)->>'avg_session_min')::numeric), 10.0,
  'session length reported in minutes');

select * from finish();
rollback;
