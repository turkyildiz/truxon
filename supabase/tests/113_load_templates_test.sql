-- R9 #118/#119: load templates + recurring spawner — due templates draft
-- honest pending loads (awaiting paperwork, tagged notes, stops copied),
-- next_run advances, future templates stay quiet, drivers see nothing.
begin;
create extension if not exists pgtap with schema extensions;
select plan(7);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-0000000000c1'::uuid, 'tpl-admin@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-0000000000c1';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000000c1"}', true);

insert into public.customers (company_name) values ('Tpl Broker');
insert into public.load_templates (name, customer_id, rate, miles, pickup_address, delivery_address, cadence, cadence_dow, next_run, stops)
select 'Chicago run', id, 2500, 400, 'Shipper, Chicago, IL', 'Receiver, Nashville, TN',
       'weekly', 1, current_date - 1,
       '[{"stop_type":"pickup","facility":"Shipper","address":"Chicago, IL"},{"stop_type":"delivery","facility":"Receiver","address":"Nashville, TN"}]'::jsonb
from public.customers where company_name='Tpl Broker';
insert into public.load_templates (name, rate, cadence, next_run)
values ('Future run', 900, 'weekly', current_date + 3);

-- 1. spawner drafts exactly the due template
select is((public.spawn_recurring_loads()->>'spawned')::int, 1, 'one due template spawns one draft');

-- 2-4. the draft is honest: pending, awaiting paperwork, tagged, stops copied
select is(
  (select status||'/'||awaiting_paperwork from public.loads where notes like '%Chicago run%'),
  'pending/true', 'draft is pending + awaiting paperwork');
select is(
  (select count(*) from public.load_stops s join public.loads l on l.id=s.load_id
    where l.notes like '%Chicago run%'),
  2::bigint, 'template stops copied onto the draft');
select is(
  (select load_number is not null and load_number <> '' from public.loads where notes like '%Chicago run%'),
  true, 'draft got a real load number');

-- 5. next_run advanced a week; re-run spawns nothing
select is(
  (select next_run from public.load_templates where name='Chicago run'),
  current_date + 6, 'weekly cadence advances next_run by 7 days');
select is((public.spawn_recurring_loads()->>'spawned')::int, 0, 'nothing due, nothing spawned');

-- 7. drivers see no templates
insert into auth.users (id, email) values ('00000000-0000-4000-8000-0000000000c2'::uuid, 'tpl-driver@test.local');
update public.profiles set role = 'driver' where id = '00000000-0000-4000-8000-0000000000c2';
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000000c2"}', true);
select is((select count(*) from public.load_templates), 0::bigint, 'driver role sees zero templates');
reset role;

select * from finish();
rollback;
