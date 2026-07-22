-- finance_extras() (20260722008003): accessorial revenue, detention capture,
-- billing lag, AR aging — computed from seeded rows; office-gated.
begin;
create extension if not exists pgtap with schema extensions;
select plan(6);

insert into auth.users (id, email) values
  ('00000000-0000-4000-8000-000000000f8a'::uuid, 'fin@test.local'),
  ('00000000-0000-4000-8000-000000000f8b'::uuid, 'drv@test.local');
update public.profiles set role = 'accountant' where id = '00000000-0000-4000-8000-000000000f8a';
update public.profiles set role = 'driver' where id = '00000000-0000-4000-8000-000000000f8b';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000f8a"}', true);

insert into public.customers (company_name) values ('Fin Broker');
-- load delivered 5 days ago, invoiced 2 days after delivery (billing lag = 2)
insert into public.invoices (invoice_number, customer_id, total, status, invoice_date)
select 'FIN-1001', id, 2000, 'sent', (current_date - 3) from public.customers where company_name = 'Fin Broker';
insert into public.loads (load_number, customer_id, status, rate, miles, delivery_time, invoice_id)
select 'FIN-L1', c.id, 'billed', 2000, 500, now() - interval '5 days', i.id
  from public.customers c join public.invoices i on i.invoice_number = 'FIN-1001' where c.company_name = 'Fin Broker';
-- detention: one captured (invoiced $375), one rejected → capture rate 50%
insert into public.load_accessorials (load_id, atype, stop_type, amount, minutes, detail, status, decided_at)
select id, 'detention', 'delivery', 375, 180, 'cap', 'invoiced', now() - interval '1 day' from public.loads where load_number = 'FIN-L1';
insert into public.load_accessorials (load_id, atype, stop_type, amount, minutes, detail, status, decided_at)
select id, 'detention', 'pickup', 150, 90, 'rej', 'rejected', now() - interval '1 day' from public.loads where load_number = 'FIN-L1';
-- a 100-day-old open invoice → lands in every AR bucket
insert into public.invoices (invoice_number, customer_id, total, status, invoice_date)
select 'FIN-1000', id, 900, 'sent', (current_date - 100) from public.customers where company_name = 'Fin Broker';

select ok(((public.finance_extras()->>'accessorial_revenue_90d')::numeric) >= 375,
  'invoiced accessorial counts as accessorial revenue');
select is(((public.finance_extras()->>'detention_capture_rate_pct')::numeric), 50.0::numeric,
  'capture rate = decided-favorably ÷ decided');
-- invoice_date is a DATE (midnight) vs delivery_time a timestamp, so the exact
-- lag shifts with wall-clock time of day — assert the ~2-day band, not equality.
select ok(((public.finance_extras()->>'billing_lag_days')::numeric) between 1.0 and 2.0,
  'billing lag = delivery → invoice, ~2 days for the seeded rows');
select ok(((public.finance_extras()->>'ar_over_90')::numeric) >= 900,
  'century-old open invoice lands in AR>90');
select ok(((public.finance_extras()->>'ar_over_45')::numeric) >= ((public.finance_extras()->>'ar_over_90')::numeric),
  'AR buckets nest (>45 ⊇ >90)');

select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000f8b"}', true);
select throws_ok('select public.finance_extras()', 'P0001', 'Not enough permissions',
  'finance_extras gated away from drivers');

select * from finish();
rollback;
