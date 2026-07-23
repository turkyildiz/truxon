-- toll double-charge sentinel: same truck/agency/plaza/amount within 10 min
-- flags once; different amounts or far-apart times stay quiet.
begin;
create extension if not exists pgtap with schema extensions;
select plan(3);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000117'::uuid, 'td@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000117';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000117"}', true);

insert into public.trucks (unit_number) values ('TD-1');

-- pair 1: true double post (2 min apart, same $) -> one finding
insert into public.toll_transactions (toll_id, vehicle_number, toll_agency_name, exit_plaza_name, toll_charge, exit_date_time, truck_id)
values ('td-a1', 'TD-1', 'IL Tollway', 'Plaza 19', 6.80, now() - interval '2 days', (select id from public.trucks where unit_number='TD-1')),
       ('td-a2', 'TD-1', 'IL Tollway', 'Plaza 19', 6.80, now() - interval '2 days' + interval '2 minutes', (select id from public.trucks where unit_number='TD-1'));
-- pair 2: same plaza, DIFFERENT charge -> quiet
insert into public.toll_transactions (toll_id, vehicle_number, toll_agency_name, exit_plaza_name, toll_charge, exit_date_time, truck_id)
values ('td-b1', 'TD-1', 'IL Tollway', 'Plaza 21', 6.80, now() - interval '3 days', (select id from public.trucks where unit_number='TD-1')),
       ('td-b2', 'TD-1', 'IL Tollway', 'Plaza 21', 4.20, now() - interval '3 days' + interval '3 minutes', (select id from public.trucks where unit_number='TD-1'));
-- pair 3: same everything but 2 hours apart (a legit re-pass) -> quiet
insert into public.toll_transactions (toll_id, vehicle_number, toll_agency_name, exit_plaza_name, toll_charge, exit_date_time, truck_id)
values ('td-c1', 'TD-1', 'IL Tollway', 'Plaza 33', 6.80, now() - interval '4 days', (select id from public.trucks where unit_number='TD-1')),
       ('td-c2', 'TD-1', 'IL Tollway', 'Plaza 33', 6.80, now() - interval '4 days' + interval '2 hours', (select id from public.trucks where unit_number='TD-1'));

select public.sentinel_scan();

select is(
  (select count(*)::int from public.trux_insights where dedup_key like 'toll_double:%'),
  1, 'exactly the true double-post pair flags');
select ok(exists (
  select 1 from public.trux_insights
   where dedup_key like 'toll_double:%' and detail like '%Plaza 19%' and detail like '%6.80%'),
  'finding names the plaza and amount');
select ok(not exists (
  select 1 from public.trux_insights
   where dedup_key like 'toll_double:%' and (detail like '%Plaza 21%' or detail like '%Plaza 33%')),
  'different-amount and re-pass pairs stay quiet');

select * from finish();
rollback;
