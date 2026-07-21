-- R3 #11: a driver sees their own week; unlinked logins get nothing.
begin;
create extension if not exists pgtap with schema extensions;
select plan(3);

insert into auth.users (id, email) values
  ('00000000-0000-4000-8000-000000000f83'::uuid, 'mw-driver@test.local'),
  ('00000000-0000-4000-8000-000000000f84'::uuid, 'mw-office@test.local');
update public.profiles set role = 'driver' where id = '00000000-0000-4000-8000-000000000f83';
update public.profiles set role = 'admin'  where id = '00000000-0000-4000-8000-000000000f84';

insert into public.customers (company_name) values ('MyWeek Broker');
insert into public.drivers (full_name, license_number, pay_per_mile, status, user_id)
values ('Week Driver', 'MW-DL-1', 0.55, 'active', '00000000-0000-4000-8000-000000000f83');

insert into public.loads (load_number, customer_id, status, delivery_time, rate, miles, driver_id)
select 'MW-1', c.id, 'completed', public.trux_week_start(current_date) + interval '1 day', 2000, 800, d.id
  from public.customers c, public.drivers d
 where c.company_name = 'MyWeek Broker' and d.full_name = 'Week Driver';

select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000f83"}', true);
select is((public.my_week_scorecard(0)->>'total_miles')::numeric, 800::numeric,
  'driver sees their own miles');
select is((public.my_week_scorecard(0)->>'est_pay')::numeric, 440.00::numeric,
  'est pay = 800 x $0.55');

select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000f84"}', true);
select is(public.my_week_scorecard(0), null, 'unlinked office login gets no card');

select * from finish();
rollback;
