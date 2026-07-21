-- R3 #3: NPS math, own-row-only inserts, anonymized office summary.
begin;
create extension if not exists pgtap with schema extensions;
select plan(7);

insert into auth.users (id, email) values
  ('00000000-0000-4000-8000-000000000f79'::uuid, 'nps-admin@test.local'),
  ('00000000-0000-4000-8000-000000000f7a'::uuid, 'nps-d1@test.local'),
  ('00000000-0000-4000-8000-000000000f7b'::uuid, 'nps-d2@test.local'),
  ('00000000-0000-4000-8000-000000000f7c'::uuid, 'nps-d3@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000f79';
update public.profiles set role = 'driver' where id in
  ('00000000-0000-4000-8000-000000000f7a','00000000-0000-4000-8000-000000000f7b','00000000-0000-4000-8000-000000000f7c');

-- 2 promoters + 1 detractor → NPS +33
insert into public.driver_nps (driver_user_id, quarter, score, comment) values
  ('00000000-0000-4000-8000-000000000f7a', '2026-Q3', 10, 'good miles'),
  ('00000000-0000-4000-8000-000000000f7b', '2026-Q3', 9, ''),
  ('00000000-0000-4000-8000-000000000f7c', '2026-Q3', 3, 'too much detention waiting');

select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000f79"}', true);
select is((select s.nps from public.driver_nps_summary() s where s.quarter = '2026-Q3'),
  33::numeric, 'NPS = (2 promoters - 1 detractor) / 3 = +33');
select is((select s.responses from public.driver_nps_summary() s where s.quarter = '2026-Q3'),
  3, 'all three responses counted');
select is((select jsonb_array_length(s.comments) from public.driver_nps_summary() s where s.quarter = '2026-Q3'),
  2, 'empty comments dropped, others ride along');
select is((select s.comments::text like '%f7a%' or s.comments::text like '%driver_user_id%'
             from public.driver_nps_summary() s where s.quarter = '2026-Q3'),
  false, 'comments carry no driver identity');

-- second submission same quarter is refused (unique)
select throws_ok(
  $$insert into public.driver_nps (driver_user_id, quarter, score)
    values ('00000000-0000-4000-8000-000000000f7a', '2026-Q3', 5)$$,
  '23505', null, 'one answer per driver per quarter');

-- a driver cannot file a survey as someone else (RLS with check)
grant select, insert on public.driver_nps to authenticated;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000f7a","role":"authenticated"}', true);
select throws_ok(
  $$insert into public.driver_nps (driver_user_id, quarter, score)
    values ('00000000-0000-4000-8000-000000000f7b', '2026-Q4', 10)$$,
  '42501', null, 'cannot answer for another driver');

-- drivers cannot read the office summary
select throws_ok('select * from public.driver_nps_summary()', 'P0001', 'Not enough permissions',
  'summary is office-only');
reset role;

select * from finish();
rollback;
