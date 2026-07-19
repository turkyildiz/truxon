-- Playbook catalog + budgets: 1,000 metrics seeded, coverage reports live vs
-- needs_data, and budget_variance compares budget to actual.
begin;
create extension if not exists pgtap with schema extensions;
select plan(7);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-0000000000b1'::uuid, 'pb@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-0000000000b1';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000000b1"}', true);

-- ---------- catalog ----------
select is((select count(*)::int from public.playbook_metrics), 1000, 'all 1,000 metrics seeded');
select is((public.playbook_coverage()->>'total')::int, 1000, 'coverage total is 1,000');
select ok((public.playbook_coverage()->'by_status'->>'live')::int between 40 and 120, 'a plausible number of metrics are live');
select ok(
  (select count(*)::int from public.playbook_metrics_list('live', null, null)) > 0
    and (select count(*)::int from public.playbook_metrics_list('live', null, null))
        = (select count(*)::int from public.playbook_metrics where status='live'),
  'playbook_metrics_list filters by status'
);
-- budget-vs-actual metrics were flipped to live by the budgets migration.
select ok(
  exists(select 1 from public.playbook_metrics where source = 'budget_variance(start,end)' and status='live'),
  'budget-variance metrics went live when budgets were instrumented'
);

-- ---------- budget variance ----------
insert into public.customers (company_name) values ('PB Broker');
insert into public.loads (customer_id, rate, miles, delivery_time, status, notes)
  select id, 10000, 1000, '2026-07-10T10:00:00Z', 'completed', 'pb-rev' from public.customers where company_name='PB Broker';
insert into public.budgets (period_month, line, amount) values ('2026-07-01','revenue', 8000);

select is(
  (select actual from public.budget_variance('2026-07-01','2026-08-01') where line='revenue'),
  10000.00::numeric, 'budget_variance actual revenue from completed loads'
);
select is(
  (select variance from public.budget_variance('2026-07-01','2026-08-01') where line='revenue'),
  2000.00::numeric, 'variance = actual 10000 − budget 8000'
);

select * from finish();
rollback;
