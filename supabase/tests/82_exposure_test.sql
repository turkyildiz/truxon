-- R3 #12: exposure math + the slow-payer haircut.
begin;
create extension if not exists pgtap with schema extensions;
select plan(4);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000f85'::uuid, 'ex@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000f85';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000f85"}', true);

insert into public.customers (company_name) values ('Exposure Broker');

-- history: $6,000 billed over 6 months → monthly $1,000 → base limit $5,000 (floor)
insert into public.invoices (invoice_number, customer_id, invoice_date, due_date, total, status, paid_at)
select 'EX-H', id, now() - interval '3 months', now() - interval '2 months', 6000, 'paid',
       now() - interval '2 months'  -- pays in ~30d: no haircut
  from public.customers where company_name = 'Exposure Broker';

-- current float: $3,000 open AR + $2,000 unbilled completed + $1,500 in-transit
insert into public.invoices (invoice_number, customer_id, invoice_date, due_date, total, status)
select 'EX-AR', id, now() - interval '10 days', now() + interval '20 days', 3000, 'sent'
  from public.customers where company_name = 'Exposure Broker';
insert into public.loads (load_number, customer_id, status, delivery_time, rate, miles)
select 'EX-UB', id, 'completed', now() - interval '2 days', 2000, 500
  from public.customers where company_name = 'Exposure Broker';
insert into public.loads (load_number, customer_id, status, rate, miles)
select 'EX-OP', id, 'in_transit', 1500, 400
  from public.customers where company_name = 'Exposure Broker';

select is((public.customer_exposure(
  (select id from public.customers where company_name = 'Exposure Broker'))->>'exposure')::numeric,
  6500::numeric, 'exposure = 3000 AR + 2000 unbilled + 1500 open');
select is((public.customer_exposure(
  (select id from public.customers where company_name = 'Exposure Broker'))->>'limit')::numeric,
  5000::numeric, 'limit floors at $5k for a small account');
select is((public.customer_exposure(
  (select id from public.customers where company_name = 'Exposure Broker'))->>'over_limit')::boolean,
  true, '6500 over a 5000 limit warns');

-- make them a slow payer: haircut halves the limit
update public.invoices set paid_at = invoice_date + interval '150 days'
 where invoice_number = 'EX-H';
select is((public.customer_exposure(
  (select id from public.customers where company_name = 'Exposure Broker'))->>'limit')::numeric,
  2500::numeric, 'slow payer (>90d) halves the limit');

select * from finish();
rollback;
