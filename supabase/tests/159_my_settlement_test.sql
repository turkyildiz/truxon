-- Driver settlement: own loads itemized with pay math; office users get null.
begin;
create extension if not exists pgtap with schema extensions;
select plan(3);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000159'::uuid, 'ms@test.local');
insert into public.customers (company_name) values ('MS Broker');
insert into public.drivers (full_name, status, pay_per_mile, empty_miles_paid, pay_per_empty_mile, user_id)
values ('MS Driver', 'active', 0.60, true, 0.30, '00000000-0000-4000-8000-000000000159');
insert into public.loads (customer_id, rate, miles, empty_miles, status, delivery_time, driver_id, load_number, pickup_state, delivery_state)
values ((select id from public.customers where company_name='MS Broker'), 2000, 500, 100, 'completed',
        public.trux_week_start(current_date)::timestamptz + interval '12 hours',
        (select id from public.drivers where full_name='MS Driver'), 'MS-1', 'OH', 'IL');

select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000159"}', true);
select is((public.my_settlement(0)->>'total_pay')::numeric, 330.00::numeric,
  '500x0.60 + 100x0.30 = 330');
select is(
  (select l->>'lane' from jsonb_array_elements(public.my_settlement(0)->'loads') l),
  'OH → IL', 'lane falls back to states');
select ok(not (public.my_settlement(0)::text like '%2000%'), 'company revenue never appears');

select * from finish();
rollback;
