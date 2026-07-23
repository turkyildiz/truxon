-- Cancellation analytics: rate + walked revenue per customer.
begin;
create extension if not exists pgtap with schema extensions;
select plan(2);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000156'::uuid, 'ca@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000156';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000156"}', true);

insert into public.customers (company_name) values ('CA Broker');
insert into public.loads (customer_id, rate, miles, status)
select (select id from public.customers where company_name='CA Broker'), 1000, 400,
       case when g = 1 then 'cancelled'::load_status else 'completed'::load_status end
  from generate_series(1, 4) g;

select is((public.cancellation_analytics(90)->>'cancel_rate_pct')::numeric, 25.0::numeric,
  '1 of 4 booked = 25% cancel rate');
select is(
  (select (x->>'revenue_walked')::numeric from jsonb_array_elements(public.cancellation_analytics(90)->'by_customer') x
    where x->>'customer' = 'CA Broker'), 1000::numeric, 'walked revenue attributed');

select * from finish();
rollback;
