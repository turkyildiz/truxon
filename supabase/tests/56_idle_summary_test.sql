-- Idle derivation: STATIONARY breadcrumb time over engine-on time, with long
-- gaps (engine off) excluded; feeds the scorecard telematics section.
begin;
create extension if not exists pgtap with schema extensions;
select plan(5);

insert into public.trucks (unit_number, status) values ('IDLE-1', 'available');

-- breadcrumb tape for one truck, 10-minute cadence:
--  3 intervals IN_MOTION (30 min) + 1 interval STATIONARY (10 min) = 25% idle,
--  then a 5-hour engine-off gap (must be excluded), then 1 more IN_MOTION pair.
insert into public.eld_location_history (id, truck_id, lat, lng, speed, status, ts)
select gen_random_uuid(), (select id from public.trucks where unit_number = 'IDLE-1'),
       41.0, -87.0, s.speed, s.status, s.ts
from (values
  (55, 'IN_MOTION',  now() - interval '10 hours'),
  (58, 'IN_MOTION',  now() - interval '9 hours 50 minutes'),
  (52, 'IN_MOTION',  now() - interval '9 hours 40 minutes'),
  (0,  'STATIONARY', now() - interval '9 hours 30 minutes'),
  (49, 'IN_MOTION',  now() - interval '9 hours 20 minutes'),
  -- 5h engine-off gap
  (60, 'IN_MOTION',  now() - interval '4 hours 20 minutes'),
  (61, 'IN_MOTION',  now() - interval '4 hours 10 minutes')
) s(speed, status, ts);

select is((public.idle_summary(30)->>'idle_hours')::numeric, 0.2::numeric,
  'one 10-minute stationary interval ≈ 0.2 idle hours');
select is((public.idle_summary(30)->>'engine_on_hours')::numeric, 0.8::numeric,
  'the 5-hour engine-off gap is excluded from engine-on time');
select is((public.idle_summary(30)->>'idle_pct')::numeric, 20.0::numeric,
  'idle pct = 10 min of 50 engine-on minutes');
select is(jsonb_array_length(public.idle_summary(30)->'trucks'), 1,
  'per-truck breakdown present');
select ok(
  (public.company_scorecard(now() - interval '7 days', now())->'telematics'->>'idle_pct_30d') is not null,
  'scorecard telematics carries idle_pct_30d');

select * from finish();
rollback;
