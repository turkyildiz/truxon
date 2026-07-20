-- Accounting: DSO/aging/unbilled math, payment recording (partials, auto-paid,
-- undo), and the admin gate.
begin;
create extension if not exists pgtap with schema extensions;
select plan(14);

-- an admin to run the module as
insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000c01'::uuid, 'acct@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000c01';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000c01"}', true);

insert into public.customers (company_name) values ('SlowPay Freight') ;
insert into public.customers (company_name) values ('FastPay Logistics');

-- open invoice, 45 days past due
insert into public.invoices (invoice_number, customer_id, invoice_date, due_date, total, status)
  select 'INV-2026-9001', id, now() - interval '75 days', now() - interval '45 days', 5000, 'sent'
  from public.customers where company_name = 'SlowPay Freight';
-- open invoice, not yet due
insert into public.invoices (invoice_number, customer_id, invoice_date, due_date, total, status)
  select 'INV-2026-9002', id, now() - interval '5 days', now() + interval '25 days', 3000, 'sent'
  from public.customers where company_name = 'FastPay Logistics';

-- an unbilled completed load (the leak)
insert into public.loads (load_number, customer_id, status, pickup_address, delivery_address, rate, delivery_time)
  select 'L-ACCT-1', id, 'completed', 'A', 'B', 2200, now() - interval '9 days'
  from public.customers where company_name = 'SlowPay Freight';

-- ── summary math ──
select is((public.acct_summary()->>'ar_total')::numeric, 8000::numeric, 'A/R totals both open invoices');
select is((public.acct_summary()->>'ar_past_due')::numeric, 5000::numeric, 'past due counts only the overdue one');
select is((public.acct_summary()->>'unbilled_count')::int, 1, 'unbilled leak detected');
select is((public.acct_summary()->>'unbilled_total')::numeric, 2200::numeric, 'unbilled dollars right');
select ok((public.acct_summary()->>'dso') is not null, 'DSO computes when there are 90-day sales');

-- ── aging buckets ──
select is(
  (select d31_60 from public.acct_aging() where customer_name = 'SlowPay Freight'),
  5000::numeric, '45-days-late lands in the 31-60 bucket');
select is(
  (select current_due from public.acct_aging() where customer_name = 'FastPay Logistics'),
  3000::numeric, 'not-yet-due lands in current');

-- ── unbilled ──
select is((select days_unbilled from public.acct_unbilled_loads() where load_number = 'L-ACCT-1'),
  9::numeric, 'unbilled age measured from delivery');

-- ── payments: partial then full ──
select is(
  (public.record_invoice_payment(
    (select id from public.invoices where invoice_number = 'INV-2026-9001'), 2000, 'check', '1042'))->>'paid',
  'false', 'partial payment leaves the invoice open');
select is((select status::text from public.invoices where invoice_number = 'INV-2026-9001'), 'sent', 'still sent after partial');
select is(
  (public.record_invoice_payment(
    (select id from public.invoices where invoice_number = 'INV-2026-9001'), 3000, 'ach'))->>'paid',
  'true', 'second payment pays in full');
select ok((select paid_at is not null from public.invoices where invoice_number = 'INV-2026-9001'), 'paid_at stamped');

-- undo the ACH payment → reopens
select lives_ok(
  format($$select public.delete_invoice_payment(%s)$$,
    (select p.id from public.invoice_payments p join public.invoices i on i.id = p.invoice_id
     where i.invoice_number = 'INV-2026-9001' and p.method = 'ach')),
  'payment can be removed');
select is((select status::text from public.invoices where invoice_number = 'INV-2026-9001'), 'sent', 'invoice reopens when payment removed');

select * from finish();
rollback;
