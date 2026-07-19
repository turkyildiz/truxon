-- Maintenance module: current-odometer bridge, the PM due engine, cost
-- analytics (CPM / by-truck / by-vendor), the playbook flip, and the Sentinel
-- maintenance findings.
begin;
create extension if not exists pgtap with schema extensions;
select plan(14);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-0000000000d1'::uuid, 'mx@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-0000000000d1';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000000d1"}', true);

-- ---------- fixtures ----------
insert into public.trucks (unit_number, plate_number, plate_expiry)
  values ('T1', 'ABC123', current_date + 10) returning id \gset t1_
insert into public.customers (company_name) values ('MX Broker') returning id \gset cust_

-- fuel-card odometer readings: prefer telematics, ignore an earlier prompted one
insert into public.fuel_transactions (uuid, transaction_time, truck_id, prompted_odometer)
  values ('mx-f0', now() - interval '10 days', :t1_id, 149000);
insert into public.fuel_transactions (uuid, transaction_time, truck_id, telematics_odometer)
  values ('mx-f1', now() - interval '2 days', :t1_id, 150000);

-- a shop, and a completed load (miles for CPM)
insert into public.maintenance_vendors (name, specialty) values ('Joe Shop', 'tires') returning id \gset v_
insert into public.loads (customer_id, rate, miles, delivery_time, status, notes)
  values (:cust_id, 12000, 10000, current_date, 'completed', 'mx-load');

-- PM done 100 days ago at 120,000 mi -> 30,000 mi since (interval 25,000) => overdue on MILES
insert into public.maintenance_records (equipment_type, truck_id, service_type, status, date_completed, odometer, cost, is_planned)
  values ('truck', :t1_id, 'pm_service', 'completed', current_date - 100, 120000, 450, true);
-- tires today (planned, vendor set) — $800
insert into public.maintenance_records (equipment_type, truck_id, service_type, status, date_completed, cost, is_planned, vendor_id)
  values ('truck', :t1_id, 'tires', 'completed', current_date, 800, true, :v_id);
-- three reactive engine repairs today — $300 each (repeat-breakdown signal)
insert into public.maintenance_records (equipment_type, truck_id, service_type, status, date_completed, cost, is_planned)
  select 'truck', :t1_id, 'engine', 'completed', current_date, 300, false from generate_series(1,3);

-- ---------- current odometer ----------
select is(public.current_odometer(:t1_id), 150000::bigint, 'current_odometer = latest telematics reading');

-- ---------- due engine ----------
select is(
  (select due_status from public.maintenance_due() where unit_number='T1' and program_name='PM Service (A)'),
  'overdue', 'PM Service (A) is overdue');
select is(
  (select miles_remaining from public.maintenance_due() where unit_number='T1' and program_name='PM Service (A)'),
  -5000::bigint, 'miles_remaining = 25000 interval − 30000 driven');

-- ---------- CPM ----------
-- window Jul 2026: tires 800 + 3×300 engine = 1700 over 10,000 miles
select is((public.maintenance_cpm('2026-07-01','2026-08-01')->>'maintenance_cpm')::numeric, 0.170, 'Maintenance CPM = 1700 / 10000');
select is((public.maintenance_cpm('2026-07-01','2026-08-01')->>'tire_cpm')::numeric, 0.080, 'Tire CPM = 800 / 10000');

-- ---------- summary + by-truck + by-vendor ----------
select is((public.maintenance_summary('2026-07-01','2026-08-01')->>'total_cost')::numeric, 1700.00, 'summary total_cost in window');
select ok((public.maintenance_summary('2026-07-01','2026-08-01')->>'pm_compliance_pct') is not null, 'pm_compliance_pct is computed');
select is(
  (select total_cost from public.maintenance_by_truck('2026-07-01','2026-08-01') where unit_number='T1'),
  1700.00::numeric, 'by_truck total_cost for T1');
select is(
  (select total_cost from public.maintenance_by_vendor('2026-07-01','2026-08-01') where vendor='Joe Shop'),
  800.00::numeric, 'by_vendor groups tire spend under Joe Shop');

-- ---------- playbook flip ----------
select ok(
  (select bool_and(status='live') from public.playbook_metrics where name in ('Maintenance CPM','Tire CPM')),
  'Maintenance CPM & Tire CPM went live');
select is((select status from public.playbook_metrics where name='PM Compliance %' limit 1), 'live', 'PM Compliance % is live');
select is((select status from public.playbook_metrics where name='Deadlined Tractors %' limit 1), 'live', 'Deadlined Tractors % is live');

-- ---------- Sentinel maintenance findings ----------
select public.sentinel_scan();
select ok(
  exists(select 1 from public.trux_insights where category='maintenance' and title like 'PM Service (A) overdue%' and status<>'resolved'),
  'Sentinel raises an overdue-PM insight');
select ok(
  exists(select 1 from public.trux_insights where dedup_key = 'repeat_repair:'||:t1_id and status<>'resolved'),
  'Sentinel raises a repeat-breakdown insight');

select * from finish();
rollback;
