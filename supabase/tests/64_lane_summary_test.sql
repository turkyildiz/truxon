-- lane_summary: state→state grouping, margin at GL all-in RPM, below-breakeven flag.
begin;
create extension if not exists pgtap with schema extensions;
select plan(5);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000f64'::uuid, 'lane@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000f64';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000f64"}', true);

-- GL anchor: 3 prior months, costs 60000/month, miles 30000/month → all-in $2.00/mi
insert into public.gl_monthly (month, account, grp, amount)
select (date_trunc('month', now()) - (interval '1 month' * m))::date, 'Ops Expense', 'expense', 60000
from generate_series(1, 3) m;
insert into public.customers (company_name) values ('Lane Broker');
insert into public.trucks (unit_number) values ('LN-T1');
insert into public.loads (load_number, customer_id, truck_id, status, rate, miles, empty_miles, delivery_time, pickup_state, delivery_state)
select 'LN-GL-' || m, (select id from public.customers where company_name = 'Lane Broker'),
       (select id from public.trucks where unit_number = 'LN-T1'),
       'completed', 60000, 28000, 2000,
       date_trunc('month', now()) - (interval '1 month' * m) + interval '5 days', 'TX', 'CA'
from generate_series(1, 3) m;

-- a fat lane and a below-breakeven lane in the recent window
insert into public.loads (load_number, customer_id, truck_id, status, rate, miles, empty_miles, delivery_time, pickup_state, delivery_state)
values ('LN-GOOD', (select id from public.customers where company_name = 'Lane Broker'),
        (select id from public.trucks where unit_number = 'LN-T1'),
        'completed', 3000, 1000, 0, now() - interval '3 days', 'il', 'oh'),
       ('LN-BAD', (select id from public.customers where company_name = 'Lane Broker'),
        (select id from public.trucks where unit_number = 'LN-T1'),
        'completed', 1000, 1000, 0, now() - interval '4 days', 'OH', 'MI');

select is(
  (public.lane_summary(30)->>'all_in_rpm_basis')::numeric, 2.000::numeric,
  'margin basis = GL 180000 costs / 90000 total miles');
select is(
  (select e->>'lane' from jsonb_array_elements(public.lane_summary(30)->'lanes') e
    where e->>'lane' = 'IL→OH'),
  'IL→OH', 'lane states are upper-cased and grouped');
select is(
  (select (e->>'est_margin')::numeric from jsonb_array_elements(public.lane_summary(30)->'lanes') e
    where e->>'lane' = 'IL→OH'),
  1000::numeric, 'IL→OH margin = 3000 − 1000mi × $2.00');
select is(
  (select (e->>'below_breakeven')::boolean from jsonb_array_elements(public.lane_summary(30)->'lanes') e
    where e->>'lane' = 'OH→MI'),
  true, '$1.00/mi lane flagged below the $2.00 break-even');
select is(
  (select (e->>'below_breakeven')::boolean from jsonb_array_elements(public.lane_summary(30)->'lanes') e
    where e->>'lane' = 'IL→OH'),
  false, '$3.00/mi lane not flagged');

select * from finish();
rollback;
