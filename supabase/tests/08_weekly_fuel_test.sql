-- weekly_report now folds fuel into the P&L: per-truck fuel cost / gallons /
-- MPG / net-after-fuel, and fuel in the company totals with % of revenue.
begin;
create extension if not exists pgtap with schema extensions;
select plan(7);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000f08'::uuid, 'wf-admin@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000f08';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000f08"}', true);

insert into public.customers (company_name) values ('WF Fuel Broker');
insert into public.drivers (full_name, pay_per_mile) values ('WF Fuel Driver', 0.50);
insert into public.trucks (unit_number) values ('07');

-- One completed load in the week Mon 2026-07-13 .. Sun 2026-07-19: 1000 mi @ $3000.
insert into public.loads (customer_id, rate, miles, delivery_time, notes)
  select id, 3000, 1000, '2026-07-15T10:00:00Z', 'wf-fuel' from public.customers where company_name = 'WF Fuel Broker';
select set_config('app.load_rpc','1',true);
update public.loads set status='completed',
    driver_id=(select id from public.drivers where full_name='WF Fuel Driver'),
    truck_id=(select id from public.trucks where unit_number='07')
 where notes='wf-fuel';
select set_config('app.load_rpc','',true);

-- $900 / 200 gal of fuel for truck 07 in the same week (via the importer, so
-- truck matching is exercised too).
select public.import_fuel_transactions($$[
  {"uuid":"wf-f1","transaction_time":"2026-07-14T08:00:00Z","status":"Approved","merchant":"PILOT",
   "merchant_state":"TX","amount":910.00,"net_of_discount":900.00,"gallons":200.0,
   "vehicle_name":"07","vin":"","raw":{}}
]$$::jsonb);

-- ---------- per-truck fuel P&L ----------
select is(
  (select (bt->>'fuel_cost')::numeric from jsonb_array_elements(public.weekly_report('2026-07-15')->'by_truck') bt
    where bt->>'name'='07'),
  900.00::numeric, 'by_truck carries the truck''s fuel cost (net of discount)'
);
select is(
  (select (bt->>'fuel_gallons')::numeric from jsonb_array_elements(public.weekly_report('2026-07-15')->'by_truck') bt
    where bt->>'name'='07'),
  200.0::numeric, 'by_truck carries fuel gallons'
);
select is(
  (select (bt->>'mpg')::numeric from jsonb_array_elements(public.weekly_report('2026-07-15')->'by_truck') bt
    where bt->>'name'='07'),
  5.00::numeric, 'MPG = loaded miles / gallons (1000/200)'
);
select is(
  (select (bt->>'net_after_fuel')::numeric from jsonb_array_elements(public.weekly_report('2026-07-15')->'by_truck') bt
    where bt->>'name'='07'),
  2100.00::numeric, 'net after fuel = revenue - fuel cost (3000-900)'
);

-- ---------- company totals ----------
select is(
  (public.weekly_report('2026-07-15')->'totals'->>'fuel_cost')::numeric,
  900.00::numeric, 'totals include fuel cost'
);
select is(
  (public.weekly_report('2026-07-15')->'totals'->>'fuel_pct_of_revenue')::numeric,
  30.0::numeric, 'fuel as % of revenue (900/3000)'
);
select is(
  (public.weekly_report('2026-07-15')->'totals'->>'net_after_fuel')::numeric,
  2100.00::numeric, 'company net after fuel'
);

select * from finish();
rollback;
