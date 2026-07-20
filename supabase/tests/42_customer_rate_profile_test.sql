-- customer_rate_profile: the broker's trailing rate-per-mile history that sharpens
-- the load-margin panel. Averages $/mi over recent completed loads; empty for a
-- broker with no history; ignores loads outside the 180-day window.
begin;
create extension if not exists pgtap with schema extensions;
select plan(4);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000f42'::uuid, 'crp@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000f42';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000f42"}', true);

insert into public.customers (company_name) values ('Rate Broker'), ('New Broker');

-- Rate Broker: 3 recent loads at $2.00, $2.40, $2.80 /mi (1000 mi each) → avg 2.40
insert into public.loads (load_number, customer_id, status, delivery_time, rate, miles)
  select 'RB-1', id, 'billed', now() - interval '10 days', 2000, 1000 from public.customers where company_name='Rate Broker';
insert into public.loads (load_number, customer_id, status, delivery_time, rate, miles)
  select 'RB-2', id, 'completed', now() - interval '20 days', 2400, 1000 from public.customers where company_name='Rate Broker';
insert into public.loads (load_number, customer_id, status, delivery_time, rate, miles)
  select 'RB-3', id, 'billed', now() - interval '30 days', 2800, 1000 from public.customers where company_name='Rate Broker';
-- an OLD load (outside 180d) that must be ignored
insert into public.loads (load_number, customer_id, status, delivery_time, rate, miles)
  select 'RB-OLD', id, 'billed', now() - interval '400 days', 9000, 1000 from public.customers where company_name='Rate Broker';

select is((public.customer_rate_profile((select id from public.customers where company_name='Rate Broker'))->>'load_count')::int,
          3, 'counts only in-window completed/billed loads');
select is((public.customer_rate_profile((select id from public.customers where company_name='Rate Broker'))->>'avg_rpm')::numeric,
          2.40::numeric, 'average $/mi computed from recent loads');
select is((public.customer_rate_profile((select id from public.customers where company_name='Rate Broker'))->>'median_rpm')::numeric,
          2.40::numeric, 'median $/mi computed');

-- a broker with no history returns an empty profile (load_count 0), not an error
select is((public.customer_rate_profile((select id from public.customers where company_name='New Broker'))->>'load_count')::int,
          0, 'a broker with no history returns an empty profile');

select * from finish();
rollback;
