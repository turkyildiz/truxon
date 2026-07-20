-- Revenue forecast: trailing average drives the projection; when same-week-last-
-- year history exists it blends in (basis reflects it); horizon length holds.
begin;
create extension if not exists pgtap with schema extensions;
select plan(5);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-0000000000f9'::uuid, 'rf@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-0000000000f9';
insert into public.customers (company_name) values ('RF Broker');
insert into public.trucks (unit_number) values ('RF1'), ('RF2');

-- 8 recent completed weeks at ~$10k each (one load/week)
insert into public.loads (load_number, customer_id, status, delivery_time, rate, miles)
  select 'RF-'||g, (select id from public.customers where company_name='RF Broker'),
         'billed', (public.trux_week_start(current_date) - (g*7) - 3)::timestamptz, 10000, 1000
  from generate_series(1,8) g;

select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000000f9"}', true);

select is((select count(*)::int from public.revenue_forecast(6)), 6, 'forecast returns one row per horizon week');
select cmp_ok((select trailing_avg from public.revenue_forecast(6) limit 1), '>=', 9000::numeric, 'trailing average learned from recent weeks (~10k)');
select cmp_ok((select forecast_revenue from public.revenue_forecast(6) limit 1), '>', 0::numeric, 'forecast projects a positive number');
select is((select basis from public.revenue_forecast(6) limit 1), 'trailing 8-week average', 'basis is trailing avg when no last-year data');
select cmp_ok((select loads_per_truck from public.revenue_forecast(6) limit 1), '>', 0::numeric, 'utilization (loads per active truck) computed');

select * from finish();
rollback;
