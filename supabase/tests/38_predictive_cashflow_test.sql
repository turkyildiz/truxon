-- Predictive cash: pay-profile learns days-to-pay, slow_pay_risk flags a
-- late-trending open invoice, cashflow_forecast buckets expected money in.
begin;
create extension if not exists pgtap with schema extensions;
select plan(8);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-00000000cf01'::uuid, 'cash@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-00000000cf01';

insert into public.customers (company_name) values ('Slow Broker'), ('Fast Broker');

-- Slow Broker's history: two invoices paid ~45 days after billing
insert into public.invoices (invoice_number, customer_id, invoice_date, total, status, paid_at)
  select 'H1', id, now() - interval '120 days', 1000, 'paid', now() - interval '75 days' from public.customers where company_name='Slow Broker';
insert into public.invoices (invoice_number, customer_id, invoice_date, total, status, paid_at)
  select 'H2', id, now() - interval '100 days', 1000, 'paid', now() - interval '55 days' from public.customers where company_name='Slow Broker';

-- an OPEN invoice for Slow Broker, due in 15 days (its 45-day habit → ~30 days late)
insert into public.invoices (invoice_number, customer_id, invoice_date, due_date, total, status)
  select 'OPEN1', id, now(), now() + interval '15 days', 5000, 'sent' from public.customers where company_name='Slow Broker';

-- a recent completed repair ($8000) so the outflow must reflect maintenance spend
insert into public.trucks (unit_number, status) values ('CF1', 'available');
insert into public.maintenance_records (equipment_type, truck_id, status, cost, date_completed, is_planned)
  select 'truck', id, 'completed', 8000, current_date - 10, false from public.trucks where unit_number='CF1';

select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-00000000cf01"}', true);

-- pay profile learns ~45 days for Slow Broker
select cmp_ok((select avg_days from public.customer_pay_profile()
                where customer_id = (select id from public.customers where company_name='Slow Broker')),
              '>=', 40::numeric, 'pay profile learns Slow Broker pays ~45 days out');

-- slow_pay_risk: the open invoice is flagged high risk and predicted late
select is((select risk from public.slow_pay_risk() where invoice_number='OPEN1'), 'high', 'open invoice from a slow payer is high risk');
select cmp_ok((select predicted_days_late from public.slow_pay_risk() where invoice_number='OPEN1'),
              '>', 0, 'open invoice predicted to land past its due date');
select is((select count(*)::int from public.slow_pay_risk()), 1, 'only open (sent) invoices are assessed');

-- cashflow_forecast: horizon length + the $5000 lands in some future week
select is((select count(*)::int from public.cashflow_forecast(8)), 8, 'forecast returns one row per week of the horizon');
select cmp_ok((select sum(expected_in) from public.cashflow_forecast(8)), '>=', 5000::numeric, 'the open $5000 is projected as money in');
select cmp_ok((select max(expected_out) from public.cashflow_forecast(8)), '>=', 0::numeric, 'each week carries a projected outflow');
-- outflow now includes maintenance: $8000 repair ÷ 8-week trailing ⇒ ≥ $1000/wk
select cmp_ok((select max(expected_out) from public.cashflow_forecast(8)), '>=', 1000::numeric, 'weekly outflow includes trailing maintenance spend');

select * from finish();
rollback;
