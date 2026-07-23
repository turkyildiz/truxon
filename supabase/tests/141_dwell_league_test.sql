-- Dwell league: role-gated; empty data returns an empty list, not an error.
begin;
create extension if not exists pgtap with schema extensions;
select plan(2);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000141'::uuid, 'dw@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000141';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000141"}', true);

select is(jsonb_typeof(public.facility_dwell_league(45)->'facilities'), 'array',
  'league returns an array even with no measured stops');

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000142'::uuid, 'dw2@test.local');
update public.profiles set role = 'driver' where id = '00000000-0000-4000-8000-000000000142';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000142"}', true);
select throws_ok($$select public.facility_dwell_league(45)$$, null, 'Not enough permissions',
  'drivers cannot read the league');

select * from finish();
rollback;
