-- Exec reports for the Trux analyst page: fuel efficiency by driver, AR aging,
-- and the P&L summary — the numbers Trux presents, so they must be exact.
begin;
create extension if not exists pgtap with schema extensions;
select plan(9);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-0000000000e1'::uuid, 'exec@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-0000000000e1';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000000e1"}', true);

insert into public.customers (company_name) values ('EX Broker');
insert into public.drivers (full_name, pay_per_mile) values ('Thirsty Ted', 0.50), ('Frugal Fran', 0.50);
insert into public.trucks (unit_number, monthly_cost) values ('E1', 3044.00);

-- Two completed loads (window Jul 2026): Ted 1000mi, Fran 1000mi, $2000 each.
insert into public.loads (customer_id, rate, miles, delivery_time, driver_id, notes)
  select (select id from public.customers where company_name='EX Broker'), 2000, 1000, '2026-07-10T10:00:00Z',
         (select id from public.drivers where full_name='Thirsty Ted'), 'ex-ted';
insert into public.loads (customer_id, rate, miles, delivery_time, driver_id, notes)
  select (select id from public.customers where company_name='EX Broker'), 2000, 1000, '2026-07-11T10:00:00Z',
         (select id from public.drivers where full_name='Frugal Fran'), 'ex-fran';
select set_config('app.load_rpc','1',true);
update public.loads set status='completed', truck_id=(select id from public.trucks where unit_number='E1')
 where notes in ('ex-ted','ex-fran');
select set_config('app.load_rpc','',true);

-- Fuel: Ted burns 250 gal ($1000) → 4 mpg; Fran burns 100 gal ($400) → 10 mpg.
select public.import_fuel_transactions(json_build_array(
  json_build_object('uuid','ex-f1','transaction_time','2026-07-09T08:00:00Z','status','Approved',
    'amount',1000,'net_of_discount',1000,'gallons',250,'driver_name','Thirsty Ted','vehicle_name','E1','raw', json_build_object()),
  json_build_object('uuid','ex-f2','transaction_time','2026-07-09T09:00:00Z','status','Approved',
    'amount',400,'net_of_discount',400,'gallons',100,'driver_name','Frugal Fran','vehicle_name','E1','raw', json_build_object())
)::jsonb);

-- ---------- fuel_efficiency ----------
select is(
  (select driver_name from public.fuel_efficiency('2026-07-01','2026-08-01') limit 1),
  'Thirsty Ted', 'worst MPG driver is listed first'
);
select is(
  (select mpg from public.fuel_efficiency('2026-07-01','2026-08-01') where driver_name='Thirsty Ted'),
  4.00::numeric, 'Ted MPG = 1000 miles / 250 gallons'
);
select is(
  (select mpg from public.fuel_efficiency('2026-07-01','2026-08-01') where driver_name='Frugal Fran'),
  10.00::numeric, 'Fran MPG = 1000 / 100'
);
select is(
  (select fuel_cost_per_mile from public.fuel_efficiency('2026-07-01','2026-08-01') where driver_name='Thirsty Ted'),
  1.000::numeric, 'Ted fuel cost/mile = $1000 / 1000 mi'
);

-- ---------- pnl_summary ----------
-- revenue 4000; fuel 1400; tolls 0; driver_pay 1000 (2000mi*0.50); maint 0;
-- truck_fixed = 3044 * (31/30.44) ≈ 3100.02 for a full-July window.
select is(
  (public.pnl_summary('2026-07-01','2026-08-01')->>'revenue')::numeric, 4000.00::numeric, 'P&L revenue'
);
select is(
  (public.pnl_summary('2026-07-01','2026-08-01')->>'fuel_cost')::numeric, 1400.00::numeric, 'P&L fuel cost'
);
select is(
  (public.pnl_summary('2026-07-01','2026-08-01')->>'driver_pay')::numeric, 1000.00::numeric, 'P&L driver pay (2000 mi × $0.50)'
);

-- ---------- ar_aging ----------
insert into public.invoices (invoice_number, customer_id, total, status, invoice_date)
  values ('INV-2026-9001', (select id from public.customers where company_name='EX Broker'), 5000, 'sent', now() - interval '75 days');
select is(
  (select outstanding from public.ar_aging() where company_name='EX Broker'),
  5000::numeric, 'AR aging shows the outstanding sent invoice'
);
select is(
  (select d61_90 from public.ar_aging() where company_name='EX Broker'),
  5000::numeric, 'a 75-day-old invoice lands in the 61-90 bucket'
);

select * from finish();
rollback;
