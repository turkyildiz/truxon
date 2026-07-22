-- Load revenue-integrity data check (20260722009006): completed/billed loads
-- missing rate or miles fire one rolling data finding; fixing them resolves.
begin;
create extension if not exists pgtap with schema extensions;
select plan(3);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-00000000da11'::uuid, 'dg@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-00000000da11';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-00000000da11"}', true);

insert into public.customers (company_name) values ('Gap Broker');
insert into public.loads (load_number, customer_id, status, rate, miles, delivery_time)
select 'GAP-NORATE', id, 'completed', 0, 500, now() - interval '5 days' from public.customers where company_name = 'Gap Broker';
insert into public.loads (load_number, customer_id, status, rate, miles, delivery_time)
select 'GAP-NOMILES', id, 'completed', 1000, 0, now() - interval '5 days' from public.customers where company_name = 'Gap Broker';
insert into public.loads (load_number, customer_id, status, rate, miles, delivery_time)
select 'GAP-OK', id, 'completed', 1500, 400, now() - interval '5 days' from public.customers where company_name = 'Gap Broker';

select public.sentinel_scan();
select is((select title from public.trux_insights where dedup_key = 'load_data_gaps'),
  '🧮 2 billed/completed load(s) missing rate or miles',
  'flags exactly the two gap loads, not the clean one');
select ok(exists(select 1 from public.trux_insights where dedup_key = 'load_data_gaps' and status = 'open'),
  'the data-gap finding is open');

-- patch both → resolves
update public.loads set rate = 1200 where load_number = 'GAP-NORATE';
update public.loads set miles = 350 where load_number = 'GAP-NOMILES';
select public.sentinel_scan();
select is((select status from public.trux_insights where dedup_key = 'load_data_gaps'),
  'resolved', 'fixing rate + miles auto-resolves the finding');

select * from finish();
rollback;
