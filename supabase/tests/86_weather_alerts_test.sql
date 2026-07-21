-- Tablet day: weather alert ledger — exactly-once per (alert, truck), and a
-- driver sees only their own warnings.
begin;
create extension if not exists pgtap with schema extensions;
select plan(3);

insert into auth.users (id, email) values
  ('00000000-0000-4000-8000-000000000f89'::uuid, 'wx-drv@test.local'),
  ('00000000-0000-4000-8000-000000000f8a'::uuid, 'wx-drv2@test.local');
update public.profiles set role = 'driver' where id in
  ('00000000-0000-4000-8000-000000000f89', '00000000-0000-4000-8000-000000000f8a');
insert into public.trucks (unit_number, status) values ('WX1', 'available');

insert into public.weather_alerts (alert_id, truck_id, driver_user_id, event, severity, headline)
values ('nws-1', (select id from public.trucks where unit_number = 'WX1'),
        '00000000-0000-4000-8000-000000000f89', 'Winter Storm Warning', 'Severe', 'Heavy snow on I-80');

select throws_ok(
  $$insert into public.weather_alerts (alert_id, truck_id, driver_user_id, event, severity)
    values ('nws-1', (select id from public.trucks where unit_number = 'WX1'),
            '00000000-0000-4000-8000-000000000f89', 'Winter Storm Warning', 'Severe')$$,
  '23505', null, 'one warning per alert per truck — no re-push spam');

grant select on public.weather_alerts to authenticated;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000f89","role":"authenticated"}', true);
select is((select count(*)::int from public.weather_alerts), 1, 'the warned driver sees their alert');
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000f8a","role":"authenticated"}', true);
select is((select count(*)::int from public.weather_alerts), 0, 'another driver sees nothing');
reset role;

select * from finish();
rollback;
