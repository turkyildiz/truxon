-- DVIR % on the driver scorecard: pre-trip days ÷ ELD driving days, null
-- when ELD tracked nothing (no fake 100%).
begin;
create extension if not exists pgtap with schema extensions;
select plan(2);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000124'::uuid, 'sd@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000124';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000124"}', true);

insert into public.customers (company_name) values ('SD Cust');
insert into public.drivers (full_name, status, pay_per_mile) values ('SD Tracked', 'active', 0.6), ('SD Dark', 'active', 0.6);
insert into public.trucks (unit_number) values ('SD-T1'), ('SD-T2');

-- both drivers delivered a load this week
insert into public.loads (customer_id, rate, miles, status, delivery_time, driver_id, truck_id)
select (select id from public.customers where company_name='SD Cust'), 1000, 500, 'completed',
       public.trux_week_start(current_date)::timestamptz + interval '12 hours',
       d.id, t.id
  from (values ('SD Tracked','SD-T1'), ('SD Dark','SD-T2')) m(dn, tn)
  join public.drivers d on d.full_name = m.dn
  join public.trucks t on t.unit_number = m.tn;

-- SD Tracked: ELD says the truck moved 2 days this week; DVIR on only 1
insert into public.eld_daily_miles (day, truck_id, state, miles)
values (public.trux_week_start(current_date),     (select id from public.trucks where unit_number='SD-T1'), 'OH', 250),
       (public.trux_week_start(current_date) + 1, (select id from public.trucks where unit_number='SD-T1'), 'OH', 250);
insert into public.dvir (driver_id, truck_id, inspection_type, items, created_at)
values ((select id from public.drivers where full_name='SD Tracked'),
        (select id from public.trucks where unit_number='SD-T1'),
        'pre_trip', '{"brakes":"ok"}',
        public.trux_week_start(current_date)::timestamptz + interval '6 hours');

select is(
  (select (d->>'dvir_pct')::int from jsonb_array_elements(public.driver_scorecard(0)->'drivers') d
    where d->>'driver' = 'SD Tracked'),
  50, 'DVIR on 1 of 2 ELD driving days = 50%');
select ok(
  (select d->>'dvir_pct' is null from jsonb_array_elements(public.driver_scorecard(0)->'drivers') d
    where d->>'driver' = 'SD Dark'),
  'no ELD driving days = null, not a fake 100%');

select * from finish();
rollback;
