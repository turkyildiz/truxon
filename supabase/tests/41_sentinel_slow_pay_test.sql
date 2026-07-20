-- Predictive slow-pay: Sentinel warns that an OPEN invoice WILL land late based
-- on the broker's own pay history, before it is actually overdue; a fast payer's
-- invoice is left alone; paying the invoice auto-resolves the warning.
begin;
create extension if not exists pgtap with schema extensions;
select plan(6);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000f41'::uuid, 'slowpay@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000f41';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000f41"}', true);

-- SLOW broker: historically takes ~50 days to pay (invoice→paid).
insert into public.customers (company_name) values ('Slow Broker');
insert into public.invoices (invoice_number, customer_id, invoice_date, total, status, paid_at)
  select 'SP-H'||g, id, now() - interval '90 days', 1000, 'paid', now() - interval '40 days'
  from public.customers, generate_series(1,3) g where company_name = 'Slow Broker';

-- FAST broker: pays in ~8 days.
insert into public.customers (company_name) values ('Fast Broker');
insert into public.invoices (invoice_number, customer_id, invoice_date, total, status, paid_at)
  select 'FP-H'||g, id, now() - interval '90 days', 1000, 'paid', now() - interval '82 days'
  from public.customers, generate_series(1,3) g where company_name = 'Fast Broker';

-- One OPEN 'sent' invoice each, invoiced today, due in 30 days.
insert into public.invoices (invoice_number, customer_id, invoice_date, total, status, due_date)
  select 'SP-OPEN', id, now(), 4200, 'sent', now() + interval '30 days'
  from public.customers where company_name = 'Slow Broker';
insert into public.invoices (invoice_number, customer_id, invoice_date, total, status, due_date)
  select 'FP-OPEN', id, now(), 4200, 'sent', now() + interval '30 days'
  from public.customers where company_name = 'Fast Broker';

-- the profile learns each broker's cadence
select cmp_ok((select avg_days from public.customer_pay_profile()
                where customer_id = (select id from public.customers where company_name='Slow Broker')),
              '>', 45::numeric, 'slow broker profiled around 50 days-to-pay');

-- ---------- scan ----------
select public.sentinel_scan();

-- slow broker's open invoice: 50-day predicted pay vs 30-day due = ~20 late (>15) → fires
select is(
  (select category from public.trux_insights
    where dedup_key = 'slow_pay:'||(select id from public.invoices where invoice_number='SP-OPEN')),
  'cash', 'predicted-late invoice fires a cash insight');
select is(
  (select entity_type from public.trux_insights
    where dedup_key = 'slow_pay:'||(select id from public.invoices where invoice_number='SP-OPEN')),
  'customer', 'the insight points at the customer to nudge');
select ok(
  (select detail from public.trux_insights
    where dedup_key = 'slow_pay:'||(select id from public.invoices where invoice_number='SP-OPEN'))
    like '%days past%', 'detail explains the predicted lateness');

-- fast broker's open invoice: 8-day predicted pay, comfortably before due → NOT flagged
select is(
  (select count(*)::int from public.trux_insights
    where dedup_key = 'slow_pay:'||(select id from public.invoices where invoice_number='FP-OPEN')),
  0, 'a reliable payer''s invoice is not flagged');

-- ---------- auto-resolve on payment ----------
update public.invoices set status = 'paid', paid_at = now()
 where invoice_number = 'SP-OPEN';
select public.sentinel_scan();
select is(
  (select status from public.trux_insights
    where dedup_key = 'slow_pay:'||(select id from public.invoices where invoice_number='SP-OPEN')),
  'resolved', 'paying the invoice auto-resolves the slow-pay warning');

select * from finish();
rollback;
