-- R9 #129: quote pricing feedback — premiums measured against our own book,
-- unpriced/unmatchable quotes counted honestly, loss reasons surface.
begin;
create extension if not exists pgtap with schema extensions;
select plan(7);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000169'::uuid, 'qp-acct@test.local');
update public.profiles set role = 'accountant' where id = '00000000-0000-4000-8000-000000000169';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000169"}', true);

-- our book: two OH->TN loads averaging $2,000
insert into public.customers (company_name) values ('QP Broker');
insert into public.loads (customer_id, rate, miles, status, pickup_state, delivery_state)
select id, r.rate, 400, 'completed', 'OH', 'TN'
  from public.customers, (values (1900), (2100)) r(rate)
 where company_name = 'QP Broker';

insert into public.quote_requests (contact_name, email, origin_city, origin_state, dest_city, dest_state, status, quoted_rate, lost_reason) values
  ('Won Guy',  'w@x.com', 'Toledo', 'OH', 'Nashville', 'TN', 'won',  2100, ''),
  ('Lost Guy', 'l@x.com', 'Toledo', 'OH', 'Nashville', 'TN', 'lost', 2600, 'price too high'),
  ('NoRate',   'n@x.com', 'Toledo', 'OH', 'Nashville', 'TN', 'lost', null, 'went quiet'),
  ('NoLane',   'q@x.com', 'Boise',  'ID', 'Fargo',     'ND', 'won',  1500, '');

create temp table qp as select public.quote_pricing_report(180) as v;

select is((select (v->>'decided')::int from qp), 4, 'all four decided quotes in scope');
select is((select (v->>'no_rate_recorded')::int from qp), 1, 'quote without a recorded rate is counted, not hidden');
select is((select (v->>'no_lane_history')::int from qp), 1, 'priced quote on a lane we never ran is counted separately');
select is((select (v->'won'->>'avg_premium_pct')::numeric from qp), 5.0,
  'won at 2100 vs 2000 book = +5%');
select is((select (v->'lost'->>'avg_premium_pct')::numeric from qp), 30.0,
  'lost at 2600 vs 2000 book = +30% — the pricing lesson in one number');
select is((select v->'lost'->'top_reasons'->0->>'reason' from qp), 'price too high', 'loss reasons surface');

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000170'::uuid, 'qp-drv@test.local');
update public.profiles set role = 'driver' where id = '00000000-0000-4000-8000-000000000170';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000170"}', true);
select throws_ok($$ select public.quote_pricing_report() $$,
  'Not enough permissions', 'driver role is refused');

select * from finish();
rollback;
