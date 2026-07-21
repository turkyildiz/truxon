-- ensure_auto_budget heals stale $0 auto lines; manual and nonzero auto rows stay.
begin;
create extension if not exists pgtap with schema extensions;
select plan(3);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000f62'::uuid, 'bh@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000f62';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000f62"}', true);

-- actuals inside the trailing-3-month window
insert into public.customers (company_name) values ('Budget Heal Broker');
insert into public.trucks (unit_number) values ('BH-T1');
insert into public.loads (load_number, customer_id, status, rate, miles, delivery_time, truck_id)
values ('BH-1', (select id from public.customers where company_name = 'Budget Heal Broker'),
        'completed', 9000, 3000, now() - interval '60 days',
        (select id from public.trucks where unit_number = 'BH-T1'));
insert into public.fuel_transactions (uuid, truck_id, transaction_time, gallons, amount, status)
values ('bh-fuel-1', (select id from public.trucks where unit_number = 'BH-T1'),
        now() - interval '60 days', 700, 3000, 'Settled');

-- stale zero auto line, a nonzero auto line, and a manual line
insert into public.budgets (period_month, line, amount, basis) values
  (date_trunc('month', now())::date, 'fuel', 0, 'auto'),
  (date_trunc('month', now())::date, 'revenue', 999, 'auto'),
  (date_trunc('month', now())::date, 'total_cost', 77, 'manual');

select public.ensure_auto_budget();

select is(
  (select amount from public.budgets where period_month = date_trunc('month', now())::date and line = 'fuel'),
  1000.00::numeric, 'stale $0 auto fuel line healed to the trailing average');
select is(
  (select amount from public.budgets where period_month = date_trunc('month', now())::date and line = 'revenue'),
  999::numeric, 'nonzero auto line is not overwritten');
select is(
  (select amount from public.budgets where period_month = date_trunc('month', now())::date and line = 'total_cost'),
  77::numeric, 'manual line is never touched');

select * from finish();
rollback;
