-- R9 #65/#73: forecast MAPE scores matured snapshots vs actuals; the
-- retirement what-if models redistributing a unit's freight.
begin;
create extension if not exists pgtap with schema extensions;
select plan(7);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-00000000019d'::uuid, 'fm-admin@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-00000000019d';
insert into auth.users (id, email) values ('00000000-0000-4000-8000-00000000019e'::uuid, 'fm-drv@test.local');
update public.profiles set role = 'driver' where id = '00000000-0000-4000-8000-00000000019e';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-00000000019d"}', true);

insert into public.customers (company_name) values ('FM Broker');

-- #65: a matured forecast for last week (predicted 10000) and the realized
-- revenue for that same week (8000) → 25% error.
insert into public.forecast_snapshots (metric, made_on, target_week, predicted)
values ('revenue_week', current_date - 14, public.trux_week_start(current_date) - 7, 10000);
insert into public.loads (customer_id, rate, miles, status, delivery_time)
select id, 8000, 3000, 'completed', (public.trux_week_start(current_date) - 7 + 2)::timestamptz
  from public.customers where company_name='FM Broker';

select is((select (public.forecast_mape_report(12)->>'weeks_scored')::int), 1, 'one matured week scored');
select is((select (public.forecast_mape_report(12)->>'mape_pct')::numeric), 25.0,
  'predicted 10k vs actual 8k = 25% error');
select ok((select (public.forecast_mape_report(12)->>'mean_bias')::numeric > 0),
  'forecasting high shows positive bias');

-- capture (service role) banks the current forward forecast
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select ok((select public.capture_revenue_forecast() >= 0), 'capture runs without error under service role');
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-00000000019d"}', true);

-- #73: a truck with recent loads yields a coherent retirement scenario
insert into public.trucks (unit_number, status, monthly_cost) values ('RT-1', 'available', 7000), ('RT-2', 'available', 7000);
insert into public.loads (customer_id, rate, miles, status, truck_id, delivery_time)
select c.id, 2000, 1000, 'completed', t.id, now() - interval '10 days'
  from public.customers c, public.trucks t where c.company_name='FM Broker' and t.unit_number='RT-1';

select is((select public.truck_retirement_scenario((select id from public.trucks where unit_number='RT-1'))->>'unit'), 'RT-1',
  'scenario names the retiring unit');
select ok((select (public.truck_retirement_scenario((select id from public.trucks where unit_number='RT-1'))->'retiring_truck'->>'monthly_fixed_saved')::numeric = 7000),
  'fixed cost saved reflects the unit monthly cost');

-- driver refused
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-00000000019e"}', true);
select throws_ok($$ select public.forecast_mape_report() $$,
  'Not enough permissions', 'driver cannot see forecast accuracy');

select * from finish();
rollback;
