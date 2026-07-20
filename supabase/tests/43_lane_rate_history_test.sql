-- lane_rate_history: what an origin→destination state lane has paid us per mile,
-- from geocoded stop states. Averages recent loads on the lane; ignores other
-- lanes and out-of-window loads; empty for a lane with no history.
begin;
create extension if not exists pgtap with schema extensions;
select plan(5);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000f43'::uuid, 'lane@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000f43';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000f43"}', true);

insert into public.customers (company_name) values ('Lane Broker');

-- TX→CA lane: three recent loads at $2.00, $2.40, $2.80 /mi (1000 mi each) → avg 2.40
insert into public.loads (load_number, customer_id, status, delivery_time, rate, miles, pickup_state, delivery_state)
  select 'LN-1', id, 'billed', now() - interval '10 days', 2000, 1000, 'TX', 'CA' from public.customers where company_name='Lane Broker';
insert into public.loads (load_number, customer_id, status, delivery_time, rate, miles, pickup_state, delivery_state)
  select 'LN-2', id, 'completed', now() - interval '20 days', 2400, 1000, 'tx', 'ca' from public.customers where company_name='Lane Broker';
insert into public.loads (load_number, customer_id, status, delivery_time, rate, miles, pickup_state, delivery_state)
  select 'LN-3', id, 'billed', now() - interval '30 days', 2800, 1000, 'TX', 'CA' from public.customers where company_name='Lane Broker';
-- a different lane (TX→FL) that must NOT be counted
insert into public.loads (load_number, customer_id, status, delivery_time, rate, miles, pickup_state, delivery_state)
  select 'LN-FL', id, 'billed', now() - interval '15 days', 5000, 1000, 'TX', 'FL' from public.customers where company_name='Lane Broker';
-- an OLD TX→CA load (outside 180d) that must be ignored
insert into public.loads (load_number, customer_id, status, delivery_time, rate, miles, pickup_state, delivery_state)
  select 'LN-OLD', id, 'billed', now() - interval '400 days', 9000, 1000, 'TX', 'CA' from public.customers where company_name='Lane Broker';

select is((public.lane_rate_history('TX', 'CA')->>'load_count')::int, 3, 'counts only in-window loads on the lane (case-insensitive)');
select is((public.lane_rate_history('TX', 'CA')->>'avg_rpm')::numeric, 2.40::numeric, 'average $/mi computed for the lane');
select is((public.lane_rate_history('TX', 'CA')->>'median_rpm')::numeric, 2.40::numeric, 'median $/mi computed for the lane');
-- the TX→FL load is a different lane
select is((public.lane_rate_history('TX', 'FL')->>'load_count')::int, 1, 'a different lane is scoped separately');
-- an unseen lane returns an empty profile, not an error
select is((public.lane_rate_history('NY', 'WA')->>'load_count')::int, 0, 'a lane with no history returns an empty profile');

select * from finish();
rollback;
