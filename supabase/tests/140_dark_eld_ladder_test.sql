-- Dark-ELD ladder: past 14 days the title carries the week count.
begin;
create extension if not exists pgtap with schema extensions;
select plan(2);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000140'::uuid, 'dl@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000140';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000140"}', true);

insert into public.trucks (unit_number, created_at) values ('DL-T', now() - interval '60 days');
insert into public.eld_vehicles (vehicle_id, number, truck_id, active)
values ('00000000-0000-4000-9000-000000000003'::uuid, 'DL-T',
        (select id from public.trucks where unit_number='DL-T'), true);
insert into public.eld_vehicle_status (vehicle_id, ts)
values ('00000000-0000-4000-9000-000000000003'::uuid, now() - interval '30 days');

select public.sentinel_scan();
select ok(exists (select 1 from public.trux_insights
  where dedup_key = 'eld_dark:'||(select id from public.trucks where unit_number='DL-T')
    and severity = 'critical' and title like '%STILL dark - week 5%'),
  '30 days dark = week-5 ladder title');
select ok(exists (select 1 from public.trux_insights
  where dedup_key = 'eld_dark:'||(select id from public.trucks where unit_number='DL-T')
    and detail ilike '%fix it this week%'), 'detail carries the action');

select * from finish();
rollback;
