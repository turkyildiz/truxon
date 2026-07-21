-- Weekly Owner Flash: composes ops/cash/safety on the Mon–Sun week standard.
begin;
create extension if not exists pgtap with schema extensions;
select plan(6);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000f59'::uuid, 'flash@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000f59';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000f59"}', true);

insert into public.customers (company_name) values ('Flash Broker');

-- one completed load this week; one open invoice + one payment this week
insert into public.loads (load_number, customer_id, status, rate, miles, delivery_time)
values ('FL-1', (select id from public.customers where company_name = 'Flash Broker'),
        'completed', 2500, 700, public.trux_week_start(current_date) + interval '2 days');

insert into public.invoices (invoice_number, customer_id, invoice_date, total, status)
values ('FL-INV', (select id from public.customers where company_name = 'Flash Broker'),
        public.trux_week_start(current_date) + 1, 2500, 'sent');
select public.record_invoice_payment(
  (select id from public.invoices where invoice_number = 'FL-INV'), 1000::numeric,
  'check', 'partial', (public.trux_week_start(current_date) + 2)::timestamptz);

select ok((public.weekly_flash()->'week'->>'label') is not null, 'week label rides the week standard');
select is((public.weekly_flash()->'ops'->>'revenue')::numeric, 2500::numeric,
  'ops revenue covers the completed load');
select is((public.weekly_flash()->'cash'->>'collected_this_week')::numeric, 1000::numeric,
  'cash collected counts this week''s payment');
select is((public.weekly_flash()->'cash'->>'invoiced_this_week')::numeric, 2500::numeric,
  'invoiced this week counts the new invoice');
select is((public.weekly_flash()->'cash'->>'ar_outstanding')::numeric, 1500::numeric,
  'AR outstanding = total minus payments');
select ok((public.weekly_flash(-1)->'week'->>'start')::date < public.trux_week_start(current_date),
  'offset walks to the prior week');

select * from finish();
rollback;
