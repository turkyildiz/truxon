-- R3 #4: a >=25% WoW lurch in a snapshotted series files a Sentinel finding;
-- settling back auto-resolves it.
begin;
create extension if not exists pgtap with schema extensions;
select plan(3);

insert into auth.users (id, email) values
  ('00000000-0000-4000-8000-000000000f7d'::uuid, 'trend-admin@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000f7d';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000f7d"}', true);

-- Seed a series that jumps 50% in the latest week: 100,100,100,100 → 150.
delete from public.metric_snapshots where metric_key = 'test.trend_spike';
insert into public.metric_snapshots (metric_key, captured_on, value)
select 'test.trend_spike', current_date - (7 * n), 100
  from generate_series(1, 4) n;
insert into public.metric_snapshots (metric_key, captured_on, value)
values ('test.trend_spike', current_date, 150);

select public.sentinel_scan();
select is(
  (select count(*) from public.trux_insights
    where dedup_key = 'trend:test.trend_spike' and status <> 'resolved')::int,
  1, 'a 50% WoW lurch files one open trend finding');
select matches(
  (select detail from public.trux_insights where dedup_key = 'trend:test.trend_spike'),
  '50\.0% WoW', 'detail carries the actual move');

-- Series settles: latest back to 100 → next scan auto-resolves.
update public.metric_snapshots set value = 100
 where metric_key = 'test.trend_spike' and captured_on = current_date;
select public.sentinel_scan();
select is(
  (select status from public.trux_insights where dedup_key = 'trend:test.trend_spike'),
  'resolved', 'settled series auto-resolves the finding');

select * from finish();
rollback;
