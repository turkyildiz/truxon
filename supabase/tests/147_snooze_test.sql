-- Snooze: brief/digest/alerts skip a snoozed finding until the date passes.
begin;
create extension if not exists pgtap with schema extensions;
select plan(3);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000148'::uuid, 'sn@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000148';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000148"}', true);

insert into public.trux_insights (dedup_key, category, severity, title, detail, entity_type, status)
values ('sn1', 'ops', 'critical', 'SN noisy finding', 'x', '', 'open');

select public.snooze_insight((select id from public.trux_insights where dedup_key='sn1'), 7);

select is((public.sentinel_open_summary()->>'open')::int, 0, 'brief skips the snoozed finding');
select is((public.sentinel_open_summary()->>'snoozed')::int, 1, 'and says how many are sleeping');
select ok(not exists (select 1 from public.sentinel_take_alerts()),
  'critical push skips it too');

select * from finish();
rollback;
