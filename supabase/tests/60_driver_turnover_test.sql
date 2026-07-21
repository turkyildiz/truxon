-- Driver turnover: leaving active stamps terminated_at, re-activating clears
-- it, and the turnover math counts stamped departures forward.
begin;
create extension if not exists pgtap with schema extensions;
select plan(6);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000f60'::uuid, 'turn@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000f60';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000f60"}', true);

insert into public.drivers (full_name, status, hire_date) values
  ('Stays Active', 'active', current_date - 400),
  ('Quits Today', 'active', current_date - 400),
  ('New Hire Quits', 'active', current_date - 30);

update public.drivers set status = 'terminated' where full_name = 'Quits Today';
select is(
  (select terminated_at from public.drivers where full_name = 'Quits Today'),
  current_date, 'leaving active stamps terminated_at');

update public.drivers set status = 'inactive' where full_name = 'New Hire Quits';
select is(
  (select terminated_at from public.drivers where full_name = 'New Hire Quits'),
  current_date, 'inactive also counts as a departure');

select is(
  (public.driver_turnover(now() - interval '30 days', now())->>'terminations_period')::int,
  2, 'both departures counted in the window');
select is(
  (public.driver_turnover(now() - interval '30 days', now())->>'first_90_day_terminations')::int,
  1, 'only the 30-day-tenure driver is a first-90-day loss');

-- re-activation clears the stamp (books were wrong, driver never left)
update public.drivers set status = 'active' where full_name = 'New Hire Quits';
select is(
  (select terminated_at from public.drivers where full_name = 'New Hire Quits'),
  null, 're-activating clears the stamp');

select ok(
  (public.company_scorecard(now() - interval '7 days', now())->'people'->>'active_drivers') is not null,
  'scorecard carries the people section');

select * from finish();
rollback;
