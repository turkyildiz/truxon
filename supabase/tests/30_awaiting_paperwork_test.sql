-- Awaiting-paperwork flag: set_load_paperwork toggles it (through the load-edit
-- guard, on any editable status), logs to activity, and is role-gated.
begin;
create extension if not exists pgtap with schema extensions;
select plan(6);

insert into auth.users (id, email) values
  ('00000000-0000-4000-8000-000000000e30'::uuid, 'disp@test.local'),
  ('00000000-0000-4000-8000-000000000e31'::uuid, 'drv@test.local');
update public.profiles set role = 'dispatcher' where id = '00000000-0000-4000-8000-000000000e30';
update public.profiles set role = 'driver' where id = '00000000-0000-4000-8000-000000000e31';

insert into public.customers (company_name) values ('Paperwork Broker');
insert into public.loads (load_number, customer_id, status)
  select 'PW-1', id, 'pending' from public.customers where company_name = 'Paperwork Broker';

-- default is false
select is((select awaiting_paperwork from public.loads where load_number = 'PW-1'), false, 'defaults to false');

-- dispatcher can flag it (pending load — guard must allow the bare column update)
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000e30"}', true);
select lives_ok($$ select public.set_load_paperwork((select id from public.loads where load_number='PW-1'), true) $$,
  'dispatcher flags awaiting paperwork');
select is((select awaiting_paperwork from public.loads where load_number = 'PW-1'), true, 'flag set to true');
select is((select count(*)::int from public.activity_log
  where entity_type='load' and action='paperwork'
    and entity_id=(select id from public.loads where load_number='PW-1')), 1, 'logged to activity');

-- clearing it works
select public.set_load_paperwork((select id from public.loads where load_number='PW-1'), false);
select is((select awaiting_paperwork from public.loads where load_number = 'PW-1'), false, 'cleared to false');

-- a driver cannot
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000e31"}', true);
select throws_like(
  $$ select public.set_load_paperwork((select id from public.loads where load_number='PW-1'), true) $$,
  '%Not enough permissions%', 'driver cannot toggle paperwork');

select * from finish();
rollback;
