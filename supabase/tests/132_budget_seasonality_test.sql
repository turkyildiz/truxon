-- Budget seasonality: prior-year same-month GL scales the seed (clamped);
-- with no prior-year sample the factor is exactly 1.0.
begin;
create extension if not exists pgtap with schema extensions;
select plan(2);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000133'::uuid, 'bs@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000133';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000133"}', true);

-- actuals for the trailing window: one delivered load = revenue 3000, avg 1000/mo
-- (pnl_summary revenue is LOADS-based, not invoice-based)
insert into public.customers (company_name) values ('BS Broker');
insert into public.loads (load_number, customer_id, status, rate, miles, delivery_time)
values ('BS-1', (select id from public.customers where company_name='BS Broker'),
        'completed', 3000, 500, date_trunc('month', now()) - interval '2 months' + interval '5 days');

-- no prior-year GL -> factor 1.0
select public.ensure_auto_budget();
select is((select amount from public.budgets
  where period_month = date_trunc('month', now())::date and line = 'revenue'),
  1000.00::numeric, 'no prior-year history: seed is the plain trailing average');

-- give this calendar month a HOT prior year (2x overall) -> factor clamps at 1.25
delete from public.budgets where period_month = date_trunc('month', now())::date and basis = 'auto';
insert into public.gl_monthly (month, account, grp, amount, source)
select mo, 'Freight Income', 'income',
       case when extract(month from mo) = extract(month from current_date) then 20000 else 8000 end,
       'test'
  from generate_series(date_trunc('month', current_date) - interval '18 months',
                       date_trunc('month', current_date) - interval '7 months',
                       interval '1 month') mo;
select public.ensure_auto_budget();
select is((select amount from public.budgets
  where period_month = date_trunc('month', now())::date and line = 'revenue'),
  1250.00::numeric, 'hot prior-year month scales the seed, clamped at 1.25x');

select * from finish();
rollback;
