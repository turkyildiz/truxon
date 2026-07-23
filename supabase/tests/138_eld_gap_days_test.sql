-- Gap-day detection: missing bank days surface per vehicle; banked days
-- (including zero-marker "confirmed parked" rows) don't.
begin;
create extension if not exists pgtap with schema extensions;
select plan(3);

insert into public.trucks (unit_number) values ('GP-T');
insert into public.eld_vehicles (vehicle_id, number, truck_id, active)
values ('00000000-0000-4000-9000-000000000001'::uuid, 'GP-T',
        (select id from public.trucks where unit_number='GP-T'), true);
-- banked: day-3 (moved) and day-4 (zero marker, confirmed parked)
insert into public.eld_daily_miles (day, truck_id, state, miles, points, path) values
  (current_date - 3, (select id from public.trucks where unit_number='GP-T'), '', 200, 500, '[]'),
  (current_date - 4, (select id from public.trucks where unit_number='GP-T'), '', 0, 0, '[]');

-- service-role context
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select ok(exists (select 1 from public.eld_gap_days(7) g
    where g.day = current_date - 5 and g.truck_id = (select id from public.trucks where unit_number='GP-T')),
  'a missing bank day surfaces as a gap');
select ok(not exists (select 1 from public.eld_gap_days(7) g where g.day = current_date - 3),
  'a banked day is not a gap');
select ok(not exists (select 1 from public.eld_gap_days(7) g where g.day = current_date - 4),
  'a confirmed-parked zero marker is not a gap');

select * from finish();
rollback;
