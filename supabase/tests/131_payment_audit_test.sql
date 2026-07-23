-- Payment-application audit: each mismatch class surfaces, clean books don't.
begin;
create extension if not exists pgtap with schema extensions;
select plan(4);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000132'::uuid, 'pa@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000132';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000132"}', true);

insert into public.customers (company_name) values ('PA Broker');
insert into public.invoices (invoice_number, customer_id, invoice_date, due_date, total, status, source, qbo_balance)
values ('PA-GHOSTPAID', (select id from public.customers where company_name='PA Broker'),
        current_date - 40, current_date - 10, 1500, 'paid', 'qbo', 1500),
       ('PA-UNMARKED', (select id from public.customers where company_name='PA Broker'),
        current_date - 40, current_date - 10, 900, 'sent', 'qbo', 0),
       ('PA-CLEAN', (select id from public.customers where company_name='PA Broker'),
        current_date - 40, current_date - 10, 700, 'paid', 'qbo', 0);
insert into public.invoices (invoice_number, customer_id, invoice_date, due_date, total, status, source)
values ('PA-OVER', (select id from public.customers where company_name='PA Broker'),
        current_date - 40, current_date - 10, 500, 'paid', 'truxon');
insert into public.invoice_payments (invoice_id, amount, method)
values ((select id from public.invoices where invoice_number='PA-OVER'), 400, 'ach'),
       ((select id from public.invoices where invoice_number='PA-OVER'), 300, 'ach');

select ok((public.payment_application_audit()->'paid_but_open_in_qbo')::text like '%PA-GHOSTPAID%',
  'paid here, open in QBO surfaces');
select ok((public.payment_application_audit()->'settled_in_qbo_but_open')::text like '%PA-UNMARKED%',
  'settled in QBO, open here surfaces');
select ok((public.payment_application_audit()->'overpaid')::text like '%PA-OVER%',
  'payments past total surface');
select ok(not (public.payment_application_audit())::text like '%PA-CLEAN%',
  'clean invoice stays out of every list');

select * from finish();
rollback;
