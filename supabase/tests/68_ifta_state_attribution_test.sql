-- IFTA state attribution: 2-state synthetic path splits, totals preserved,
-- idempotent, re-bank-safe, quarter view joins miles with fuel.
begin;
create extension if not exists pgtap with schema extensions;
select plan(12);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000f68'::uuid, 'ifta2@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000f68';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000f68"}', true);

insert into public.trucks (unit_number) values ('IF-T2');

-- due north along lng -98.0: central Kansas across the Nebraska border (lat 40.0);
-- 5 points at 10-min spacing, 0.2° apart ≈ 13.8 mi/segment, ~55.2 mi total.
-- Endpoint-half attribution: KS gets 2.5 segments (~34.5 mi), NE 1.5 (~20.7 mi).
insert into public.eld_location_history (id, truck_id, ts, lat, lng)
select gen_random_uuid(), (select id from public.trucks where unit_number = 'IF-T2'),
       (current_date - 1)::timestamptz + interval '9 hours' + (interval '10 minutes' * g),
       39.55 + 0.2 * g, -98.0
from generate_series(0, 4) g;

select public.rollup_eld_daily(current_date - 1);

select is(public.trux_state_at(39.0, -98.0), 'KS', 'point lookup: central Kansas is KS');

select is(public.ifta_attribute_states(current_date - 1), 1, 'one truck-day attributed');

select is(
  (select count(*)::int from public.eld_daily_miles
    where truck_id = (select id from public.trucks where unit_number = 'IF-T2')
      and state = ''),
  0, 'unattributed row consumed');
select is(
  (select array_agg(state order by state) from public.eld_daily_miles
    where truck_id = (select id from public.trucks where unit_number = 'IF-T2')),
  array['KS', 'NE'], 'path split into exactly KS and NE');
select ok(
  (select miles between 32 and 37 from public.eld_daily_miles
    where truck_id = (select id from public.trucks where unit_number = 'IF-T2')
      and state = 'KS'),
  'KS share ≈ 34.5 mi (2.5 of 4 segments)');
select ok(
  (select miles between 19 and 23 from public.eld_daily_miles
    where truck_id = (select id from public.trucks where unit_number = 'IF-T2')
      and state = 'NE'),
  'NE share ≈ 20.7 mi (1.5 of 4 segments)');
select ok(
  (select sum(miles) between 53 and 58 from public.eld_daily_miles
    where truck_id = (select id from public.trucks where unit_number = 'IF-T2')),
  'banked day total preserved across the split');

select is(public.ifta_attribute_states(current_date - 1), 0, 'idempotent: nothing left to attribute');

-- re-banking the day recreates the '' row; the next pass must rebuild, not double
select public.rollup_eld_daily(current_date - 1);
select is(public.ifta_attribute_states(current_date - 1), 1, 're-banked day re-attributed');
select ok(
  (select count(*) = 2 and sum(miles) between 53 and 58 from public.eld_daily_miles
    where truck_id = (select id from public.trucks where unit_number = 'IF-T2')),
  'no double count after re-bank + re-attribute');

select ok(
  (select q.miles > 30 from public.ifta_quarter(to_char(current_date - 1, 'YYYY-"Q"Q')) q
    where q.jurisdiction = 'KS'),
  'ifta_quarter reports KS miles for the quarter');

select ok(
  (public.ifta_miles_status()->>'state_attributed_pct')::numeric >= 99
  and (public.ifta_miles_status()->>'states_loaded')::int = 52,
  'status reports full attribution and 52 loaded jurisdictions');

select * from finish();
rollback;
