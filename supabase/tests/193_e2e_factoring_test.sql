-- READINESS #178: factoring lifecycle end-to-end — how the money actually
-- arrives fast. create → complete → invoice → send → factor (Denim, with fee)
-- → the invoice carries the factor + fee, the factoring overview counts it and
-- its fee sliver, and un-factoring reverses cleanly. Proves the whole
-- get-paid-early path ties together, not just its pieces.
begin;
create extension if not exists pgtap with schema extensions;
select plan(8);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-0000000001a8'::uuid, 'fac-acct@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-0000000001a8';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000001a8"}', true);

insert into public.customers (company_name) values ('Factor Broker');
insert into public.loads (customer_id, rate, miles, status, delivery_time)
select id, 3000, 700, 'completed', now() - interval '1 day' from public.customers where company_name='Factor Broker';

-- invoice the completed load, then send it
select public.create_invoice((select id from public.customers where company_name='Factor Broker'),
                             array[(select id from public.loads where rate=3000)]);
create temp table I as select invoice_id as id from public.loads where rate=3000;
select public.set_invoice_status((select id from I), 'sent');
select is((select status from public.invoices where id=(select id from I)), 'sent', '1. invoice sent, ready to factor');

-- ── FACTOR it via Denim with a $60 (2%) fee ──
select public.mark_invoice_factored((select id from I), 'Denim', 60.00);
select is((select factored_at is not null from public.invoices where id=(select id from I)), true,
  '2. factored_at stamped');
select is((select factor_name from public.invoices where id=(select id from I)), 'Denim', '3. factor recorded');
select is((select factoring_fee from public.invoices where id=(select id from I)), 60.00, '4. fee recorded');

-- ── the factoring overview reflects it ──
select is((select (public.factoring_overview()->'summary'->>'factored_count')::int), 1, '5. overview counts the factored invoice');
select is((select (public.factoring_overview()->'summary'->>'fees')::numeric), 60.00, '6. overview totals the fee sliver');
select is((select (public.factoring_overview()->'summary'->>'total_factored')::numeric), 3000.00, '7. overview totals the face');

-- ── un-factor reverses cleanly (a correction) ──
select public.unmark_invoice_factored((select id from I));
select is((select (public.factoring_overview()->'summary'->>'factored_count')::int), 0, '8. un-factoring drops it from the overview');

select * from finish();
rollback;
