-- READINESS #186: driver storage ownership — the RLS helpers that gate what a
-- driver can read/write in the documents + fuel buckets. driver_owns_load(),
-- driver_owns_load_path('load/<id>/…') and driver_owns_fuel_path('fuel/<did>/…')
-- decide, per storage object, whether the signed-in driver owns it. Two things
-- must hold: (a) a driver owns only their own load/fuel objects, never a peer's,
-- and (b) these run INSIDE storage RLS, so a malformed object name must return
-- false, never throw — a throw would break the whole policy evaluation.
begin;
create extension if not exists pgtap with schema extensions;
select plan(13);

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-4000-8000-0000000f0001'::uuid, 'own-d1@test.local',   '{"role":"driver"}'::jsonb),
  ('00000000-0000-4000-8000-0000000f0002'::uuid, 'own-d2@test.local',   '{"role":"driver"}'::jsonb),
  ('00000000-0000-4000-8000-0000000f00ff'::uuid, 'own-disp@test.local', '{"role":"dispatcher"}'::jsonb);
insert into public.drivers (full_name, status, user_id) values
  ('Own Driver One', 'active', '00000000-0000-4000-8000-0000000f0001'),
  ('Own Driver Two', 'active', '00000000-0000-4000-8000-0000000f0002');
insert into public.customers (company_name) values ('Own Broker');
insert into public.loads (customer_id, rate, miles, status, driver_id, load_number, delivery_time)
select c.id, 1500, 400, 'assigned', d.id, 'OWN-1', now()+interval '1 day'
  from public.customers c, public.drivers d where c.company_name='Own Broker' and d.full_name='Own Driver One';
insert into public.loads (customer_id, rate, miles, status, driver_id, load_number, delivery_time)
select c.id, 1500, 400, 'assigned', d.id, 'OWN-2', now()+interval '1 day'
  from public.customers c, public.drivers d where c.company_name='Own Broker' and d.full_name='Own Driver Two';

create temp table K as select
  (select id from public.loads where load_number='OWN-1') as l1,
  (select id from public.loads where load_number='OWN-2') as l2,
  (select id from public.drivers where full_name='Own Driver One') as d1,
  (select id from public.drivers where full_name='Own Driver Two') as d2;

-- ═══ as driver one ═══
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000f0001"}', true);

select is(public.driver_owns_load((select l1 from K)), true,  '1. owns own load');
select is(public.driver_owns_load((select l2 from K)), false, '2. does not own the peer load');
select is(public.driver_owns_load(999999999),          false, '3. a nonexistent load is not owned');

select is(public.driver_owns_load_path(format('load/%s/abc123_bol.jpg', (select l1 from K))), true,
  '4. owns an object under its own load path');
select is(public.driver_owns_load_path(format('load/%s/abc123_bol.jpg', (select l2 from K))), false,
  '5. cannot reach an object under the peer load path');
select is(public.driver_owns_load_path('load/not-a-number/x.jpg'), false,
  '6. a malformed load id returns false (never throws in the policy)');
select is(public.driver_owns_load_path('totally/other/key'), false,
  '7. an unrelated object key returns false');

select is(public.driver_owns_fuel_path(format('fuel/%s/receipt.jpg', (select d1 from K))), true,
  '8. owns its own fuel-receipt path (segment 2 is the driver id)');
select is(public.driver_owns_fuel_path(format('fuel/%s/receipt.jpg', (select d2 from K))), false,
  '9. cannot reach another driver''s fuel path');
select is(public.driver_owns_fuel_path('fuel/xyz/receipt.jpg'), false,
  '10. a malformed fuel path returns false (never throws)');

-- ═══ as a non-driver (office) ═══
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000f00ff"}', true);
select is(public.driver_owns_load((select l1 from K)), false,
  '11. a non-driver owns no load object');
select is(public.driver_owns_load_path(format('load/%s/x.jpg', (select l1 from K))), false,
  '12. a non-driver owns no load path');
-- fuel helper returns NULL (not false) when my_driver_id is null: `id = null` → null.
-- In RLS `using(...)` NULL filters the row out, so access is denied either way;
-- assert the contract that matters — it never evaluates to true (never grants).
select ok(public.driver_owns_fuel_path(format('fuel/%s/x.jpg', (select d1 from K))) is not true,
  '13. a non-driver is never granted a fuel path (null/false, never true)');

select * from finish();
rollback;
