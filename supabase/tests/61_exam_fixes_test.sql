-- Forest final-exam fixes: pay-profile names, outstanding-based scorecard AR,
-- fleet_cost_basis coverage-window MPG + GL-anchored break-even.
begin;
create extension if not exists pgtap with schema extensions;
select plan(8);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000f61'::uuid, 'exam@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000f61';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000f61"}', true);

insert into public.customers (company_name) values ('Named Broker Test');
insert into public.invoices (customer_id, invoice_number, status, total, invoice_date, paid_at)
values ((select id from public.customers where company_name = 'Named Broker Test'),
        'EXM-1', 'paid', 1000, now() - interval '40 days', now() - interval '10 days');
insert into public.invoices (customer_id, invoice_number, status, total, invoice_date)
values ((select id from public.customers where company_name = 'Named Broker Test'),
        'EXM-2', 'sent', 1000, now() - interval '20 days');

select is(
  (select p.customer from public.customer_pay_profile() p
    where p.customer_id = (select id from public.customers where company_name = 'Named Broker Test')),
  'Named Broker Test', 'pay profile carries the customer NAME');
select is(
  (select p.avg_days from public.customer_pay_profile() p
    where p.customer_id = (select id from public.customers where company_name = 'Named Broker Test')),
  30.0::numeric, 'avg days-to-pay math unchanged');

-- partial payment: scorecard AR must count the 600 balance, not the 1000 face
select public.record_invoice_payment(
  (select id from public.invoices where invoice_number = 'EXM-2'), 400::numeric,
  'ach', 'exam-test', now());
select is(
  (select public.invoice_balance(i) from public.invoices i where i.invoice_number = 'EXM-2'),
  600::numeric, 'invoice balance reflects the partial payment');
select ok(
  (public.company_scorecard(now() - interval '30 days', now())->'financial'->>'ar_outstanding')::numeric
    = (select coalesce(sum(public.invoice_balance(i)), 0) from public.invoices i where i.status = 'sent'),
  'scorecard AR equals summed OUTSTANDING balances, not face totals');

-- fleet_cost_basis: fuel only in the last 10 days; an old delivered load outside
-- coverage must NOT inflate MPG; the recent load inside coverage counts.
insert into public.trucks (unit_number) values ('EXM-T1');
insert into public.loads (load_number, customer_id, status, rate, miles, empty_miles, delivery_time, truck_id)
values ('EXM-OLD', (select id from public.customers where company_name = 'Named Broker Test'),
        'completed', 2000, 50000, 0, now() - interval '60 days',
        (select id from public.trucks where unit_number = 'EXM-T1')),
       ('EXM-NEW', (select id from public.customers where company_name = 'Named Broker Test'),
        'completed', 2000, 800, 200, now() - interval '2 days',
        (select id from public.trucks where unit_number = 'EXM-T1'));
insert into public.fuel_transactions (uuid, truck_id, transaction_time, gallons, amount, status)
values ('exm-fuel-1', (select id from public.trucks where unit_number = 'EXM-T1'),
        now() - interval '5 days', 125, 500, 'Settled');

select ok(
  ((public.fleet_cost_basis())->>'mpg')::numeric <= 12,
  'MPG computed over the fuel-coverage window only (old miles excluded)');

-- GL anchor: seed 3 prior full months of books → basis flips to gl and
-- break-even equals GL costs / total miles of those months.
insert into public.gl_monthly (month, account, grp, amount)
select (date_trunc('month', now()) - (interval '1 month' * m))::date, acct, grp, amt
from generate_series(1, 3) m,
     (values ('Freight Income', 'income', 90000::numeric), ('Fuel', 'expense', 30000::numeric),
             ('Vendor Expense', 'expense', 24000::numeric)) as t(acct, grp, amt);
insert into public.loads (load_number, customer_id, status, rate, miles, empty_miles, delivery_time, truck_id)
select 'EXM-GL-' || m,
       (select id from public.customers where company_name = 'Named Broker Test'),
       'completed', 5000, 25000, 2000,
       date_trunc('month', now()) - (interval '1 month' * m) + interval '5 days',
       (select id from public.trucks where unit_number = 'EXM-T1')
from generate_series(1, 3) m;

select is(
  (public.fleet_cost_basis())->>'basis', 'gl', 'break-even anchors to the books when GL exists');
select is(
  ((public.fleet_cost_basis())->>'breakeven_rpm')::numeric,
  -- 162000 GL costs / (81000 seeded + 50000 from EXM-OLD, also in-window) miles
  1.24::numeric, 'GL break-even = trailing-3-month costs over total miles');
select ok(
  ((public.fleet_cost_basis())->>'fixed_per_mile')::numeric >= 0,
  'residual fixed-per-mile never negative');

select * from finish();
rollback;
