-- speeding_summary(): time-weighted minutes over thresholds from breadcrumb
-- speeds, and the speeding_hot sentinel firing at the warn/critical bars.
begin;
create extension if not exists pgtap with schema extensions;
select plan(5);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000109'::uuid, 'spd@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000109';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000109"}', true);

insert into public.trucks (unit_number) values ('SPD-1'), ('SPD-2');

-- SPD-1: 40 min at 82 mph (critical: >=15 min over 80), 1-min spacing
insert into public.eld_location_history (id, truck_id, ts, lat, lng, speed, calc_location)
select gen_random_uuid(), (select id from public.trucks where unit_number='SPD-1'),
       now() - interval '3 days' + (interval '1 minute' * g),
       41.8, -87.6, case when g < 40 then 82 else 55 end, 'I-80 near Joliet, IL'
from generate_series(0, 90) g;

-- SPD-2: brief 76-mph blip (5 min) — under both bars, must stay quiet
insert into public.eld_location_history (id, truck_id, ts, lat, lng, speed)
select gen_random_uuid(), (select id from public.trucks where unit_number='SPD-2'),
       now() - interval '2 days' + (interval '1 minute' * g),
       41.8, -87.6, case when g < 5 then 76 else 60 end
from generate_series(0, 60) g;

select ok(
  (select (t->>'min_over_80')::numeric between 35 and 45
     from jsonb_array_elements(public.speeding_summary(14)->'trucks') t
    where t->>'unit' = 'SPD-1'),
  'SPD-1: ~40 time-weighted minutes over 80');
select is(
  (select t->>'worst_place' from jsonb_array_elements(public.speeding_summary(14)->'trucks') t
    where t->>'unit' = 'SPD-1'),
  'I-80 near Joliet, IL', 'worst moment carries the place');

select public.sentinel_scan();

select ok(exists (
  select 1 from public.trux_insights
   where dedup_key = 'speeding_hot:' || (select id from public.trucks where unit_number='SPD-1')
     and severity = 'critical' and status <> 'resolved'),
  'SPD-1 fires CRITICAL (>=15 min over 80)');
select ok(not exists (
  select 1 from public.trux_insights
   where dedup_key = 'speeding_hot:' || (select id from public.trucks where unit_number='SPD-2')),
  'SPD-2 brief blip stays quiet');
select ok(
  (select status from public.playbook_metrics where number = 262) = 'live',
  'playbook #262 flipped live');

select * from finish();
rollback;
