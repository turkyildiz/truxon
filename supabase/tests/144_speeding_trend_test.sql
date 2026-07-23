-- Speeding trend: this-week vs last-week minutes at 75+.
begin;
create extension if not exists pgtap with schema extensions;
select plan(1);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000145'::uuid, 'st@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000145';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000145"}', true);

insert into public.trucks (unit_number) values ('ST-1');
-- two pings 10 min apart at 80 mph inside THIS week (week start + 1h is
-- always in the past-or-now portion of the current week)
insert into public.eld_location_history (id, vehicle_id, truck_id, lat, lng, speed, ts) values
  (gen_random_uuid(), gen_random_uuid(), (select id from public.trucks where unit_number='ST-1'), 40, -83, 80,
   public.trux_week_start(current_date)::timestamptz + interval '1 hour'),
  (gen_random_uuid(), gen_random_uuid(), (select id from public.trucks where unit_number='ST-1'), 40, -83, 80,
   public.trux_week_start(current_date)::timestamptz + interval '1 hour 10 minutes');

select is(
  (select (t->>'this_week_min')::numeric from jsonb_array_elements(public.speeding_trend()->'trucks') t
    where t->>'unit' = 'ST-1'), 10.0::numeric, '10 minutes at 80 mph counted this week');

select * from finish();
rollback;
