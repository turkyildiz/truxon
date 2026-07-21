-- GT-06: profiles roster is office-only; a driver login sees just their row.
begin;
create extension if not exists pgtap with schema extensions;
select plan(4);

insert into auth.users (id, email) values
  ('00000000-0000-4000-8000-000000000f72'::uuid, 'rls-admin@test.local'),
  ('00000000-0000-4000-8000-000000000f73'::uuid, 'rls-driver@test.local'),
  ('00000000-0000-4000-8000-000000000f74'::uuid, 'rls-driver2@test.local');
update public.profiles set role = 'admin'  where id = '00000000-0000-4000-8000-000000000f72';
update public.profiles set role = 'driver' where id in
  ('00000000-0000-4000-8000-000000000f73', '00000000-0000-4000-8000-000000000f74');

-- Local resets don't reproduce prod's default table grants (verified live:
-- prod authenticated has SELECT). Supply it here — rolled back with the
-- transaction — so the assertions exercise the POLICY, which is what ships.
grant select on public.profiles to authenticated;

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000f73","role":"authenticated"}', true);
select is((select count(*) from public.profiles)::int, 1,
  'driver sees exactly one profiles row');
select is((select id from public.profiles),
  '00000000-0000-4000-8000-000000000f73'::uuid,
  'and that row is their own');

select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000f72","role":"authenticated"}', true);
select cmp_ok((select count(*) from public.profiles)::int, '>=', 3,
  'admin still sees the whole roster');
select is((select count(*) from public.profiles where role = 'driver' and id in
  ('00000000-0000-4000-8000-000000000f73','00000000-0000-4000-8000-000000000f74'))::int, 2,
  'including both seeded drivers');
reset role;

select * from finish();
rollback;
