-- Trend infra: the flattener turns scorecard jsonb into series rows, capture
-- is idempotent per day, and metric_trends computes WoW/MoM/slope off history.
begin;
create extension if not exists pgtap with schema extensions;
select plan(8);

-- flattener: nested numeric leaves only, dotted paths
select is(
  (select count(*)::int from public.metric_flatten('t',
    '{"a": 1, "b": {"c": 2.5, "d": "text", "e": null}, "f": true}'::jsonb)),
  2, 'flatten keeps only numeric leaves');
select is(
  (select value from public.metric_flatten('t', '{"b": {"c": 2.5}}'::jsonb)
    where metric_key = 't.b.c'),
  2.5, 'flatten builds dotted paths');

-- capture writes a series and re-running the same day upserts, not duplicates
select ok(public.capture_metric_snapshots() > 0, 'capture writes snapshot rows');
select lives_ok('select public.capture_metric_snapshots()', 'same-day recapture upserts cleanly');
select is(
  (select count(*)::int from public.metric_snapshots
    where captured_on = current_date and metric_key like 'scorecard7.%'
    group by captured_on limit 1) > 0,
  true, 'scorecard leaves landed in the series');

-- seed a controlled series for one key and check the math
delete from public.metric_snapshots where metric_key = 'test.revenue';
insert into public.metric_snapshots (metric_key, captured_on, value) values
  ('test.revenue', current_date - 28, 1000),
  ('test.revenue', current_date - 7,  1100),
  ('test.revenue', current_date,      1210);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000f61'::uuid, 'trend@test.local');
update public.profiles set role = 'accountant' where id = '00000000-0000-4000-8000-000000000f61';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000f61"}', true);

select is(
  (select wow from public.metric_trends('test.') where metric_key = 'test.revenue'),
  110::numeric, 'WoW delta = latest minus the ~7-day-old point');
select is(
  (select wow_pct from public.metric_trends('test.') where metric_key = 'test.revenue'),
  10.00::numeric, 'WoW percent is computed against the prior value');
select is(
  (select mom from public.metric_trends('test.') where metric_key = 'test.revenue'),
  210::numeric, 'MoM delta uses the ~28-day-old point');

select * from finish();
rollback;
