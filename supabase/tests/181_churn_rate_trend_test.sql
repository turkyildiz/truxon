-- R9 #68/#69: churn-watch flags still-booking-but-slowing customers (not the
-- gone-silent ones), and lane-rate-trend sorts falling vs rising lanes.
begin;
create extension if not exists pgtap with schema extensions;
select plan(7);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000199'::uuid, 'cw-disp@test.local');
update public.profiles set role = 'dispatcher' where id = '00000000-0000-4000-8000-000000000199';
insert into auth.users (id, email) values ('00000000-0000-4000-8000-00000000019a'::uuid, 'cw-drv@test.local');
update public.profiles set role = 'driver' where id = '00000000-0000-4000-8000-00000000019a';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000199"}', true);

insert into public.customers (company_name) values ('Slowing Broker'), ('Steady Broker');

-- Slowing: 8 loads in the 60–180d baseline (≈2/30d), only 1 in the last 60d
-- (≈0.5/30d) → ~75% drop, still booking.
insert into public.loads (customer_id, rate, miles, status, created_at)
select id, 1000, 400, 'completed', now() - (g || ' days')::interval
  from public.customers, generate_series(65, 170, 15) g where company_name='Slowing Broker';
insert into public.loads (customer_id, rate, miles, status, created_at)
select id, 1000, 400, 'completed', now() - interval '20 days' from public.customers where company_name='Slowing Broker';

-- Steady: even cadence across both windows → no drop.
insert into public.loads (customer_id, rate, miles, status, created_at)
select id, 1000, 400, 'completed', now() - (g || ' days')::interval
  from public.customers, generate_series(10, 175, 15) g where company_name='Steady Broker';

-- 1-2. churn watch surfaces the slowing customer, not the steady one
select is((select jsonb_array_length(public.customer_churn_watch(4, 40)->'watch')), 1,
  'one customer flagged as slowing');
select is((select public.customer_churn_watch(4, 40)->'watch'->0->>'customer'), 'Slowing Broker',
  'the slowing broker is named');

-- 3. a customer with ZERO recent bookings is NOT in churn-watch (that's the sentinel's job)
delete from public.loads where customer_id = (select id from public.customers where company_name='Slowing Broker')
  and created_at > now() - interval '60 days';
select is((select jsonb_array_length(public.customer_churn_watch(4, 40)->'watch')), 0,
  'a gone-silent customer drops off churn-watch (still-booking only)');

-- #69 lane rate trend: OH→TN paid $2.50/mi last year, $2.00/mi recently (falling);
-- IL→GA paid $1.50 then $2.00 (rising).
insert into public.customers (company_name) values ('Lane Broker');
insert into public.loads (customer_id, rate, miles, status, pickup_state, delivery_state, created_at)
select id, r.rate, 1000, 'completed', r.o, r.d, r.at::timestamptz from public.customers,
  (values
    (2500,'OH','TN', (now()-interval '200 days')::text),(2500,'OH','TN',(now()-interval '210 days')::text),
    (2500,'OH','TN',(now()-interval '220 days')::text),(2500,'OH','TN',(now()-interval '230 days')::text),
    (2000,'OH','TN',(now()-interval '10 days')::text),(2000,'OH','TN',(now()-interval '20 days')::text),
    (2000,'OH','TN',(now()-interval '30 days')::text),(2000,'OH','TN',(now()-interval '40 days')::text),
    (1500,'IL','GA',(now()-interval '200 days')::text),(1500,'IL','GA',(now()-interval '210 days')::text),
    (1500,'IL','GA',(now()-interval '220 days')::text),(1500,'IL','GA',(now()-interval '230 days')::text),
    (2000,'IL','GA',(now()-interval '10 days')::text),(2000,'IL','GA',(now()-interval '20 days')::text),
    (2000,'IL','GA',(now()-interval '30 days')::text),(2000,'IL','GA',(now()-interval '40 days')::text)
  ) r(rate,o,d,at) where company_name='Lane Broker';

select is((select public.lane_rate_trend(4, 8)->'falling'->0->>'lane'), 'OH→TN',
  'the softening lane is flagged as falling');
select ok((select (public.lane_rate_trend(4, 8)->'falling'->0->>'move_pct')::numeric < 0),
  'falling lane has a negative move');
select is((select public.lane_rate_trend(4, 8)->'rising'->0->>'lane'), 'IL→GA',
  'the strengthening lane is flagged as rising');

-- 7. driver refused
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-00000000019a"}', true);
select throws_ok($$ select public.lane_rate_trend() $$,
  'Not enough permissions', 'driver cannot see rate trends');

select * from finish();
rollback;
