-- Section G flips: tenure math + dispatch productivity + flips recorded.
begin;
create extension if not exists pgtap with schema extensions;
select plan(3);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000149'::uuid, 'pg@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000149';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000149"}', true);

insert into public.drivers (full_name, status, hire_date) values
  ('PG Old', 'active', (current_date - interval '4 years')::date),
  ('PG New', 'active', (current_date - interval '6 months')::date);

select is((public.driver_tenure_summary()->>'over_3y')::int, 1, 'tenure buckets fill');
select ok((public.driver_tenure_summary()->>'median_months')::numeric between 20 and 34,
  'median lands between the two hires');
select is((select count(*)::int from public.playbook_metrics
  where number in (70, 241, 434, 515, 516) and status = 'live'), 5,
  'the five G-section flips are recorded live');

select * from finish();
rollback;
