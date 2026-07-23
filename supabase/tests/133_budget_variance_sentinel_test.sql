-- Budget-variance sentinel: 20%+ over two months running fires; one bad
-- month doesn't.
begin;
create extension if not exists pgtap with schema extensions;
select plan(2);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000134'::uuid, 'bv@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000134';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000134"}', true);

-- maintenance budget $100 both prior months; actuals $150 both -> fires
insert into public.budgets (period_month, line, amount, basis) values
  ((date_trunc('month', now()) - interval '1 month')::date, 'maintenance', 100, 'manual'),
  ((date_trunc('month', now()) - interval '2 months')::date, 'maintenance', 100, 'manual'),
  ((date_trunc('month', now()) - interval '1 month')::date, 'driver_pay', 100, 'manual');
insert into public.trucks (unit_number) values ('BV-1');
insert into public.maintenance_records (equipment_type, truck_id, service_type, status, date_completed, cost, description)
select 'truck', (select id from public.trucks where unit_number='BV-1'), 'brakes', 'completed',
       (date_trunc('month', now()) - (interval '1 month' * g) + interval '5 days')::date, 150, 'x'
  from generate_series(1, 2) g;

select public.sentinel_scan();
select ok(exists (select 1 from public.trux_insights
  where dedup_key = 'budget_over:maintenance' and severity = 'warn' and status <> 'resolved'),
  '20%+ over two months running fires');
select ok(not exists (select 1 from public.trux_insights
  where dedup_key = 'budget_over:driver_pay' and status <> 'resolved'),
  'a line without two over-budget months stays quiet');

select * from finish();
rollback;
