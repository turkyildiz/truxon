-- driver_scorecard: weekly per-driver revenue/pay math + violations count.
begin;
create extension if not exists pgtap with schema extensions;
select plan(5);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000f65'::uuid, 'ds@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000f65';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000f65"}', true);

insert into public.customers (company_name) values ('Card Broker');
insert into public.drivers (full_name, status, pay_per_mile) values ('Card Driver', 'active', 0.70);
insert into public.loads (load_number, customer_id, driver_id, status, rate, miles, empty_miles, delivery_time, equipment_type)
values ('DS-1', (select id from public.customers where company_name = 'Card Broker'),
        (select id from public.drivers where full_name = 'Card Driver'),
        'completed', 4200, 1500, 0,
        public.trux_week_start(current_date) + interval '1 day', '53'' Van'),
       ('DS-TEAM', (select id from public.customers where company_name = 'Card Broker'),
        (select id from public.drivers where full_name = 'Card Driver'),
        'completed', 1000, 300, 0,
        public.trux_week_start(current_date) + interval '2 days', 'Team Driver Needed');
insert into public.safety_events (event_type, event_date, driver_id, severity)
values ('violation', public.trux_week_start(current_date) + 1,
        (select id from public.drivers where full_name = 'Card Driver'), 'minor');

select is(
  (public.driver_scorecard()->'drivers'->0->>'driver'), 'Card Driver', 'card carries the driver name');
select is(
  (public.driver_scorecard()->'drivers'->0->>'revenue')::numeric, 5200::numeric,
  'weekly revenue sums both loads');
select is(
  (public.driver_scorecard()->'drivers'->0->>'est_pay')::numeric, 1260::numeric,
  'pay = 1800 miles at $0.70');
select is(
  (public.driver_scorecard()->'drivers'->0->>'violations')::int, 1,
  'HOS/violation count rides safety_events');
select is(
  (public.driver_scorecard()->>'solo_revenue_per_driver_per_week')::numeric, 4200::numeric,
  'solo revenue excludes the team-equipment load');

select * from finish();
rollback;
