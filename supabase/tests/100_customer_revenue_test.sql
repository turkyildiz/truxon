-- customer_revenue_extras() (20260722009002): unprofitable count, top/bottom
-- decile profit, avg relationship years — built on customer_keep_fire margins.
begin;
create extension if not exists pgtap with schema extensions;
select plan(3);

insert into auth.users (id, email) values
  ('00000000-0000-4000-8000-00000000a0a0'::uuid, 'rev@test.local'),
  ('00000000-0000-4000-8000-00000000a0a1'::uuid, 'drv@test.local');
update public.profiles set role = 'accountant' where id = '00000000-0000-4000-8000-00000000a0a0';
update public.profiles set role = 'driver' where id = '00000000-0000-4000-8000-00000000a0a1';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-00000000a0a0"}', true);

-- two customers; one with a completed load 2 years ago (relationship length),
-- one recent. keep_fire will score whoever has revenue.
insert into public.customers (company_name) values ('Rev A'), ('Rev B');
insert into public.loads (load_number, customer_id, status, rate, miles, delivery_time, created_at)
select 'REV-A1', id, 'completed', 3000, 600, now() - interval '30 days', now() - interval '2 years'
  from public.customers where company_name = 'Rev A';
insert into public.loads (load_number, customer_id, status, rate, miles, delivery_time, created_at)
select 'REV-B1', id, 'completed', 2500, 500, now() - interval '20 days', now() - interval '60 days'
  from public.customers where company_name = 'Rev B';

select ok((public.customer_revenue_extras() ? 'unprofitable_customer_count'),
  'scorecard returns unprofitable count');
-- avg relationship: (2y + ~0.16y)/2 ≈ 1.08 — assert it saw both customers' first loads
select ok(((public.customer_revenue_extras()->>'avg_relationship_years')::numeric) > 0.9,
  'avg relationship length reflects the 2-year-old account');

select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-00000000a0a1"}', true);
select throws_ok('select public.customer_revenue_extras()', 'P0001', 'Not enough permissions',
  'customer_revenue_extras gated away from drivers');

select * from finish();
rollback;
