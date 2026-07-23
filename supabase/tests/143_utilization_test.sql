-- Truck utilization: moving vs parked days from the ELD bank; unbanked days
-- stay out of the denominator.
begin;
create extension if not exists pgtap with schema extensions;
select plan(2);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000144'::uuid, 'ut@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000144';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000144"}', true);

insert into public.trucks (unit_number) values ('UT-1');
insert into public.eld_daily_miles (day, truck_id, state, miles) values
  (current_date - 3, (select id from public.trucks where unit_number='UT-1'), '', 300),
  (current_date - 4, (select id from public.trucks where unit_number='UT-1'), '', 250),
  (current_date - 5, (select id from public.trucks where unit_number='UT-1'), '', 0);

select is(
  (select (t->>'moving_days')::int from jsonb_array_elements(public.truck_utilization(28)->'trucks') t
    where t->>'unit' = 'UT-1'), 2, 'two moving days counted');
select is(
  (select (t->>'parked_days')::int from jsonb_array_elements(public.truck_utilization(28)->'trucks') t
    where t->>'unit' = 'UT-1'), 1, 'the confirmed-parked zero marker counts as sitting');

select * from finish();
rollback;
