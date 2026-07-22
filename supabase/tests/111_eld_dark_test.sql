-- dark-ELD sentinel: a 6-month-dark unit fires critical; a fresh one is quiet;
-- a brand-new truck gets grace.
begin;
create extension if not exists pgtap with schema extensions;
select plan(3);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000112'::uuid, 'dark@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000112';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000112"}', true);

insert into public.trucks (unit_number, created_at) values
  ('DRK-1', now() - interval '90 days'),   -- dark for months → critical
  ('DRK-2', now() - interval '90 days'),   -- fresh ELD → quiet
  ('DRK-3', now() - interval '2 days');    -- new truck → grace period

insert into public.eld_vehicles (vehicle_id, number, active, truck_id) values
  ('44444444-4444-4444-8444-444444444401', 'DRK-1', true, (select id from public.trucks where unit_number='DRK-1')),
  ('44444444-4444-4444-8444-444444444402', 'DRK-2', true, (select id from public.trucks where unit_number='DRK-2'));
insert into public.eld_vehicle_status (vehicle_id, ts, odometer) values
  ('44444444-4444-4444-8444-444444444401', now() - interval '180 days', 100000),
  ('44444444-4444-4444-8444-444444444402', now() - interval '1 hour', 200000);

select public.sentinel_scan();

select ok(exists (
  select 1 from public.trux_insights
   where dedup_key = 'eld_dark:' || (select id from public.trucks where unit_number='DRK-1')
     and severity = 'critical' and status <> 'resolved'),
  'six-months-dark ELD fires critical');
select ok(not exists (
  select 1 from public.trux_insights
   where dedup_key = 'eld_dark:' || (select id from public.trucks where unit_number='DRK-2')),
  'fresh ELD stays quiet');
select ok(not exists (
  select 1 from public.trux_insights
   where dedup_key = 'eld_dark:' || (select id from public.trucks where unit_number='DRK-3')),
  'brand-new truck gets the 7-day grace');

select * from finish();
rollback;
