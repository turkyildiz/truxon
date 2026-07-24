-- R9 #170/#171: the banker + tax packages assemble real data, name their
-- gaps, and stay behind the right role gates.
begin;
create extension if not exists pgtap with schema extensions;
select plan(9);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000187'::uuid, 'ep-admin@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000187';
insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000188'::uuid, 'ep-acct@test.local');
update public.profiles set role = 'accountant' where id = '00000000-0000-4000-8000-000000000188';
insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000189'::uuid, 'ep-drv@test.local');
update public.profiles set role = 'driver' where id = '00000000-0000-4000-8000-000000000189';

insert into public.trucks (unit_number, year, make, model, vin, status, purchase_price, purchase_date)
values ('EP-1', 2022, 'Freightliner', 'Cascadia', '1FUJ0000000000001', 'available', 150000, '2024-01-15'),
       ('EP-OLD', 2010, 'Volvo', 'VNL', '1V00000000000002', 'retired', 90000, '2015-01-01');
insert into public.fuel_transactions (uuid, merchant_state, gallons, amount, transaction_time, status)
values ('ft-ep-1', 'OH', 100, 400, make_timestamptz(2026, 2, 10, 12, 0, 0), 'Approved'),
       ('ft-ep-2', 'IN', 80, 320, make_timestamptz(2026, 5, 10, 12, 0, 0), 'Approved');

-- #170 banker package: admin only, carries fleet + a gap-honest note
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000187"}', true);
select is((select (public.banker_package(12)->'fleet'->>'power_units')::int), 1,
  'retired trucks excluded from the fleet count');
select ok((select public.banker_package(12)->'fleet'->'trucks'->0->>'vin' = '1FUJ0000000000001'),
  'active truck VIN is in the fleet list');
select ok((select public.banker_package(12) ? 'balance_ratios'), 'balance ratios folded in');
select ok((select public.banker_package(12)->>'note' like '%not audited%'),
  'package labels itself a worksheet, not audited statements');

-- #171 tax package: four IFTA quarters, HVUT list, honest weight caveat
select is((select jsonb_array_length(public.tax_season_package(2026)->'ifta_fuel_by_quarter')), 4,
  'four calendar quarters of IFTA fuel');
select is((select public.tax_season_package(2026)->'ifta_fuel_by_quarter'->0->'by_state'->0->>'jurisdiction'), 'OH',
  'Q1 fuel attributed to the purchase state');
select ok((select public.tax_season_package(2026)->'hvut_2290'->>'note' like '%weight is not tracked%'),
  '2290 list flags the missing taxable-weight field');

-- role gates
select is((public.tax_season_package(2026) ? 'depreciation'), true, 'admin gets depreciation block');
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000189"}', true);
select throws_ok($$ select public.banker_package(12) $$,
  'Not enough permissions', 'driver is refused the banker package');

select * from finish();
rollback;
