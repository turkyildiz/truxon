-- eld_daily_miles rollup: haversine miles, gap/glitch guard, thinned path.
begin;
create extension if not exists pgtap with schema extensions;
select plan(4);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000f67'::uuid, 'ifta@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000f67';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000f67"}', true);

insert into public.trucks (unit_number) values ('IF-T1');

-- straight run north along a meridian: 4 points, 0.5° apart ≈ 34.5 mi each,
-- 10-minute spacing; then a 2-hour gap to a far point (must be EXCLUDED).
insert into public.eld_location_history (id, truck_id, ts, lat, lng)
select gen_random_uuid(), (select id from public.trucks where unit_number = 'IF-T1'),
       (current_date - 1)::timestamptz + interval '8 hours' + (interval '10 minutes' * g),
       40.0 + 0.5 * g, -89.0
from generate_series(0, 3) g;
insert into public.eld_location_history (id, truck_id, ts, lat, lng)
values (gen_random_uuid(), (select id from public.trucks where unit_number = 'IF-T1'),
        (current_date - 1)::timestamptz + interval '12 hours', 45.0, -95.0);

select public.rollup_eld_daily(current_date - 1);

select is(
  (select count(*)::int from public.eld_daily_miles
    where day = current_date - 1
      and truck_id = (select id from public.trucks where unit_number = 'IF-T1')),
  1, 'one rollup row per truck per day');
select ok(
  (select miles between 100 and 110 from public.eld_daily_miles
    where day = current_date - 1
      and truck_id = (select id from public.trucks where unit_number = 'IF-T1')),
  'three half-degree segments ≈ 104 mi; the 2-hour-gap jump excluded');
select ok(
  (select jsonb_array_length(path) between 4 and 5 from public.eld_daily_miles
    where day = current_date - 1
      and truck_id = (select id from public.trucks where unit_number = 'IF-T1')),
  'thinned path keeps the 10-minute-spaced points');
select ok(
  (public.ifta_miles_status()->>'days_banked')::int >= 1
  and (public.ifta_miles_status()->>'state_attributed_pct')::numeric = 0,
  'status reports banked days and 0% state attribution honestly');

select * from finish();
rollback;
