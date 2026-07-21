-- R3 #8: weekly feature capture banks miles + reactive MX; the 4-week
-- breakdown label backfills only after its horizon passes.
begin;
create extension if not exists pgtap with schema extensions;
select plan(5);

insert into public.trucks (unit_number, status, year) values ('BF1', 'available', 2019);

-- last full week: 900 banked miles, one $800 unplanned repair
insert into public.eld_daily_miles (day, truck_id, state, miles, points)
select date_trunc('week', current_date - 7)::date + n,
       (select id from public.trucks where unit_number = 'BF1'), 'OH', 300, 50
  from generate_series(0, 2) n;
insert into public.maintenance_records (equipment_type, truck_id, date_completed, description, cost, is_planned, status)
values ('truck', (select id from public.trucks where unit_number = 'BF1'),
        date_trunc('week', current_date - 7)::date + 1, 'road call — alternator', 800, false, 'completed');

select ok(public.capture_truck_features() >= 1, 'capture banks at least our truck');
select is((select f.miles from public.truck_weekly_features f
            join public.trucks t on t.id = f.truck_id where t.unit_number = 'BF1'),
  900::numeric, 'week miles from the ELD bank');
select is((select f.reactive_count from public.truck_weekly_features f
            join public.trucks t on t.id = f.truck_id where t.unit_number = 'BF1'),
  1, 'unplanned repair counted');
select is((select f.breakdown_next_4w from public.truck_weekly_features f
            join public.trucks t on t.id = f.truck_id where t.unit_number = 'BF1'),
  null::boolean, 'label stays null until the 4-week horizon passes');

-- an OLD banked week whose horizon has passed gets its label on next capture
insert into public.truck_weekly_features (week_start, truck_id, miles)
values (current_date - 70, (select id from public.trucks where unit_number = 'BF1'), 500);
insert into public.maintenance_records (equipment_type, truck_id, date_completed, description, cost, is_planned, status)
values ('truck', (select id from public.trucks where unit_number = 'BF1'),
        current_date - 55, 'breakdown — coolant', 1200, false, 'completed');
select public.capture_truck_features();
select is((select f.breakdown_next_4w from public.truck_weekly_features f
            where f.week_start = current_date - 70), true,
  'passed horizon backfills the breakdown label');

select * from finish();
rollback;
