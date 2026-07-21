-- segment_economics math, quick ratio, and widened snapshot capture.
begin;
create extension if not exists pgtap with schema extensions;
select plan(7);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000f63'::uuid, 'seg@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000f63';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000f63"}', true);

insert into public.customers (company_name) values ('Segment Broker'), ('Churned Broker');
insert into public.trucks (unit_number) values ('SEG-T1');
insert into public.drivers (full_name, status, pay_per_mile) values ('Seg Driver', 'active', 0.65);

-- current 7-day window: one completed load; prior window: only Churned Broker
insert into public.loads (load_number, customer_id, driver_id, truck_id, status, rate, miles, empty_miles, delivery_time)
values ('SEG-1', (select id from public.customers where company_name = 'Segment Broker'),
        (select id from public.drivers where full_name = 'Seg Driver'),
        (select id from public.trucks where unit_number = 'SEG-T1'),
        'completed', 7000, 2000, 0, now() - interval '2 days'),
       ('SEG-OLD', (select id from public.customers where company_name = 'Churned Broker'),
        null, null, 'completed', 3000, 1000, 0, now() - interval '10 days');

select is(
  (public.segment_economics(now() - interval '7 days', now())->'fleet'->>'revenue_per_tractor_per_week')::numeric,
  7000::numeric, 'revenue per tractor per week over a 1-week window');
select is(
  (public.segment_economics(now() - interval '7 days', now())->'by_customer'->0->>'customer'),
  'Segment Broker', 'by_customer carries the customer name');
select is(
  (public.segment_economics(now() - interval '7 days', now())->'by_driver'->0->>'est_pay')::numeric,
  1300::numeric, 'driver pay = 2000 miles at $0.65');
select is(
  (public.segment_economics(now() - interval '7 days', now())->'fleet'->>'customer_churn_pct')::numeric,
  100.0::numeric, 'prior-window-only broker counts as churned');
select is(
  (public.segment_economics(now() - interval '7 days', now())->'fleet'->>'multi_stop_load_pct')::numeric,
  0.0::numeric, 'no extra stops → 0% multi-stop');

-- quick ratio off the balance mirror
insert into public.bs_snapshot (as_of, cash, ar, ap, current_assets, current_liabilities, total_assets, total_liabilities, equity)
values (current_date, 10000, 20000, 5000, 35000, 15000, 100000, 60000, 40000);
select is(
  (public.gl_balance_ratios()->>'quick_ratio')::numeric,
  2.00::numeric, 'quick ratio = (cash + AR) / current liabilities');

-- widened capture writes the new series
select public.capture_metric_snapshots();
select ok(
  exists (select 1 from public.metric_snapshots where metric_key = 'ar.over_60' and captured_on = current_date)
  and exists (select 1 from public.metric_snapshots where metric_key like 'segments30.%' and captured_on = current_date),
  'nightly capture includes ar.over_60 and segments30.* series');

select * from finish();
rollback;
