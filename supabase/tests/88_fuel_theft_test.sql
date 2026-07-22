-- Fuel-theft detection: non-diesel fuel on a diesel truck, cash advances on the
-- fuel card, and a tank-overflow single fill surface as Sentinel findings; the
-- fuel_efficiency_by_truck RPC surfaces the non-diesel gallons and is office-gated.
begin;
create extension if not exists pgtap with schema extensions;
select plan(6);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000f88'::uuid, 'fuel@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000f88';

insert into public.trucks (unit_number, status) values ('TT88', 'available');

insert into public.fuel_transactions (uuid, truck_id, transaction_time, gallons, amount, fuel_type)
select 'ft88-'||g.k, (select id from public.trucks where unit_number='TT88'),
       now() - (g.d||' days')::interval, g.gal, g.amt, g.ft
  from (values
    ('gas',  3, 90,  480, 'Unleaded Regular'),  -- product mismatch
    ('cash1',4, 0,   600, 'Other'),             -- cash advance
    ('cash2',2, 0,   600, 'Other'),             -- cash advance
    ('over', 1, 260, 900, 'Diesel')             -- tank overflow
  ) as g(k, d, gal, amt, ft);

select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000f88"}', true);
select public.sentinel_scan();

select is(
  (select count(*)::int from public.trux_insights
     where dedup_key = 'fuel_product:'||(select id from public.trucks where unit_number='TT88')
       and status <> 'resolved'),
  1, 'non-diesel fuel on a diesel truck fires fuel_product');

select is(
  (select count(*)::int from public.trux_insights
     where dedup_key = 'fuel_cash:'||(select id from public.trucks where unit_number='TT88')
       and status <> 'resolved'),
  1, 'cash advances on the fuel card fire fuel_cash');

select is(
  (select count(*)::int from public.trux_insights
     where dedup_key like 'fuel_overflow:%'
       and entity_id = (select id from public.trucks where unit_number='TT88')
       and status <> 'resolved'),
  1, 'oversized single fill fires fuel_overflow');

select is(
  (select severity from public.trux_insights
     where dedup_key = 'fuel_product:'||(select id from public.trucks where unit_number='TT88')),
  'critical', 'product mismatch is critical');

select ok(
  (select nondiesel_gallons from public.fuel_efficiency_by_truck(30)
     where truck_id = (select id from public.trucks where unit_number='TT88')) >= 90,
  'fuel_efficiency_by_truck surfaces the 90 non-diesel gallons');

-- a driver (non-office) cannot call the RPC
insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000d88'::uuid, 'drv@test.local');
update public.profiles set role = 'driver' where id = '00000000-0000-4000-8000-000000000d88';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000d88","role":"authenticated"}', true);
select throws_ok(
  $$ select * from public.fuel_efficiency_by_truck(30) $$,
  NULL, NULL, 'fuel_efficiency_by_truck is not open to drivers');

select * from finish();
rollback;
