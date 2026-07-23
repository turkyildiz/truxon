-- Revenue-recognition drift: a load delivered in one month but invoiced the
-- next shows up as cross-month revenue in its DELIVERY month.
begin;
create extension if not exists pgtap with schema extensions;
select plan(2);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000130'::uuid, 'rr@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000130';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000130"}', true);

insert into public.customers (company_name) values ('RR Broker');
insert into public.invoices (invoice_number, customer_id, invoice_date, due_date, total, status, source)
values ('RR-1', (select id from public.customers where company_name='RR Broker'),
        date_trunc('month', current_date)::date + 2, current_date + 30, 800, 'sent', 'truxon');
-- delivered LAST month, invoiced THIS month
insert into public.loads (customer_id, rate, miles, status, delivery_time, invoice_id)
values ((select id from public.customers where company_name='RR Broker'), 800, 400, 'billed',
        (date_trunc('month', current_date) - interval '10 days'),
        (select id from public.invoices where invoice_number='RR-1'));

select is(
  (select (m->>'cross_month_amount')::numeric from jsonb_array_elements(public.rev_rec_drift(3)->'months') m
    where m->>'month' = to_char(date_trunc('month', current_date) - interval '1 month', 'YYYY-MM')),
  800::numeric, 'cross-month load lands in its delivery month');
select is(
  (select (m->>'invoiced')::numeric from jsonb_array_elements(public.rev_rec_drift(3)->'months') m
    where m->>'month' = to_char(current_date, 'YYYY-MM')),
  800::numeric, 'the booked side lands in the invoice month');

select * from finish();
rollback;
