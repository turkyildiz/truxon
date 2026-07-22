-- chronic-idler sentinel: >35% idle over 14d fires an ops finding; a lightly
-- used truck under the 7-idle-hour floor stays quiet.
begin;
create extension if not exists pgtap with schema extensions;
select plan(3);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000108'::uuid, 'idle@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000108';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000108"}', true);

insert into public.trucks (unit_number) values ('IDL-1'), ('IDL-2');

-- IDL-1: 20 engine-on hours, 10 of them STATIONARY (50% idle, 10 idle hrs)
-- breadcrumbs every 5 min so gaps stay under the 15-min engine-off cap
insert into public.eld_location_history (id, truck_id, ts, lat, lng, status)
select gen_random_uuid(), (select id from public.trucks where unit_number='IDL-1'),
       now() - interval '2 days' + (interval '5 minutes' * g),
       41.8, -87.6, case when g < 120 then 'STATIONARY' else 'IN_MOTION' end
from generate_series(0, 240) g;

-- IDL-2: only 2 engine-on hours, half idle — under the floor, must NOT fire
insert into public.eld_location_history (id, truck_id, ts, lat, lng, status)
select gen_random_uuid(), (select id from public.trucks where unit_number='IDL-2'),
       now() - interval '1 day' + (interval '5 minutes' * g),
       41.8, -87.6, case when g < 12 then 'STATIONARY' else 'IN_MOTION' end
from generate_series(0, 24) g;

select public.sentinel_scan();

select ok(exists (
  select 1 from public.trux_insights
   where dedup_key = 'idle_chronic:' || (select id from public.trucks where unit_number='IDL-1')
     and status <> 'resolved' and category = 'ops'),
  'IDL-1 (50% idle, 10 idle hrs) fires the chronic-idler finding');
select ok((
  select title like 'Unit IDL-1 idles %' and detail like '%idle hours%'
    from public.trux_insights
   where dedup_key = 'idle_chronic:' || (select id from public.trucks where unit_number='IDL-1')),
  'finding names the unit and quantifies the waste');
select ok(not exists (
  select 1 from public.trux_insights
   where dedup_key = 'idle_chronic:' || (select id from public.trucks where unit_number='IDL-2')),
  'IDL-2 under the idle-hour floor stays quiet');

select * from finish();
rollback;
