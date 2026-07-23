-- Breakdown flow: a driver report files an unplanned MX item AND a critical
-- ops insight; office logins are refused.
begin;
create extension if not exists pgtap with schema extensions;
select plan(5);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000160'::uuid, 'bk-drv@test.local');
update public.profiles set role = 'driver' where id = '00000000-0000-4000-8000-000000000160';
insert into public.trucks (unit_number, status) values ('BK1', 'available');
insert into public.drivers (full_name, license_number, status, user_id)
values ('Broke Driver', 'BK-DL-1', 'active', '00000000-0000-4000-8000-000000000160');

select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000160"}', true);

select ok(
  (public.report_breakdown(
     (select id from public.trucks where unit_number = 'BK1'),
     'blown steer tire', false, 41.12345, -85.54321) ->> 'maintenance_id') is not null,
  'driver can report a breakdown');
select is(
  (select count(*)::int from public.maintenance_records
    where source = 'breakdown' and needs_review and not is_planned
      and description like '%NOT DRIVABLE%' and description like '%41.12345%'),
  1, 'unplanned MX item filed with location + not-drivable marker');
select is(
  (select count(*)::int from public.trux_insights
    where dedup_key like 'breakdown:%' and severity = 'critical' and category = 'ops'
      and status = 'open'),
  1, 'critical ops insight opened');

select throws_ok(
  $$ select public.report_breakdown((select id from public.trucks where unit_number = 'BK1'), '') $$,
  '22023', 'Description required', 'empty description refused');

-- an office login is not a driver
insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000161'::uuid, 'bk-office@test.local');
update public.profiles set role = 'dispatcher' where id = '00000000-0000-4000-8000-000000000161';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000161"}', true);
select throws_ok(
  $$ select public.report_breakdown((select id from public.trucks where unit_number = 'BK1'), 'engine light') $$,
  '42501', 'Not enough permissions', 'office users cannot file driver breakdowns');

select * from finish();
rollback;
