-- READINESS #180: driver isolation — the mobile-app attack surface. Five
-- SECURITY DEFINER RPCs are granted to `authenticated`, so any signed-in
-- driver can call them. This proves the ownership gates hold: a driver sees
-- and mutates ONLY their own load, never a peer's, and the legal status
-- transitions are the only ones a driver can drive. If any of these gates
-- is wrong, one driver can read or move another driver's freight.
begin;
create extension if not exists pgtap with schema extensions;
select plan(14);

-- ── two linked drivers + one office user ──
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-4000-8000-0000000d0001'::uuid, 'iso-d1@test.local', '{"role":"driver"}'::jsonb),
  ('00000000-0000-4000-8000-0000000d0002'::uuid, 'iso-d2@test.local', '{"role":"driver"}'::jsonb),
  ('00000000-0000-4000-8000-0000000d00ff'::uuid, 'iso-disp@test.local', '{"role":"dispatcher"}'::jsonb);

insert into public.drivers (full_name, status, user_id) values
  ('Iso Driver One', 'active', '00000000-0000-4000-8000-0000000d0001'),
  ('Iso Driver Two', 'active', '00000000-0000-4000-8000-0000000d0002');

insert into public.customers (company_name) values ('Iso Broker');

-- one assigned load each
insert into public.loads (customer_id, rate, miles, status, driver_id, load_number, delivery_time)
select c.id, 1500, 400, 'assigned', d.id, 'ISO-1', now() + interval '1 day'
  from public.customers c, public.drivers d
 where c.company_name='Iso Broker' and d.full_name='Iso Driver One';
insert into public.loads (customer_id, rate, miles, status, driver_id, load_number, delivery_time)
select c.id, 1600, 420, 'assigned', d.id, 'ISO-2', now() + interval '1 day'
  from public.customers c, public.drivers d
 where c.company_name='Iso Broker' and d.full_name='Iso Driver Two';

create temp table L as
  select (select id from public.loads where load_number='ISO-1') as l1,
         (select id from public.loads where load_number='ISO-2') as l2;

-- a POD document on driver one's load
insert into public.documents (entity_type, entity_id, doc_type, filename, storage_path)
select 'load', l1, 'pod', 'iso1-pod.pdf', 'loads/iso1/pod.pdf' from L;

-- ═══ act as DRIVER ONE ═══
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000d0001"}', true);

-- 1. my_loads shows own load, not the peer's
select is(
  (select count(*)::int from jsonb_array_elements(public.driver_my_loads()) e
    where e->>'load_number' = 'ISO-1'), 1, '1. driver one sees own load');
select is(
  (select count(*)::int from jsonb_array_elements(public.driver_my_loads()) e
    where e->>'load_number' = 'ISO-2'), 0, '2. driver one never sees the peer load');

-- 2. get_load: own works, peer is walled off
select is((public.driver_get_load((select l1 from L))->>'load_number'), 'ISO-1',
  '3. driver one can fetch own load');
select throws_ok(
  format('select public.driver_get_load(%s)', (select l2 from L)),
  '42501', 'Not your load', '4. driver one cannot fetch the peer load');

-- 3. list_documents: own works, peer is walled off
select is(
  (select count(*)::int from jsonb_array_elements(public.driver_list_documents((select l1 from L)))), 1,
  '5. driver one sees own load documents');
select throws_ok(
  format('select public.driver_list_documents(%s)', (select l2 from L)),
  '42501', 'Not your load', '6. driver one cannot list the peer load documents');

-- 4. change_load_status: legal step works, skip is refused, peer is walled off
select lives_ok(
  format('select public.driver_change_load_status(%s, ''in_transit'')', (select l1 from L)),
  '7. driver one drives own load assigned → in_transit');
select is((select status from public.loads where id=(select l1 from L)), 'in_transit',
  '8. status actually advanced');
select throws_ok(
  format('select public.driver_change_load_status(%s, ''completed'')', (select l1 from L)),
  'P0001', null, '9. driver cannot jump straight to completed');
select throws_ok(
  format('select public.driver_change_load_status(%s, ''in_transit'')', (select l2 from L)),
  '42501', 'Not your load', '10. driver one cannot move the peer load');

-- 5. set_duty stamps on-duty for the active driver
select is((public.driver_set_duty(true)).is_on_duty, true, '11. driver can go on duty');
select is(
  (select is_on_duty from public.driver_duty where driver_id = public.my_driver_id()), true,
  '12. duty row persisted');

-- ═══ act as OFFICE (dispatcher, not a linked driver) ═══
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000d00ff"}', true);
select throws_ok(
  'select public.driver_my_loads()',
  '42501', 'Not a linked driver', '13. a non-driver cannot use the driver feed');
select throws_ok(
  format('select public.driver_get_load(%s)', (select l1 from L)),
  '42501', 'Not enough permissions', '14. a non-driver cannot fetch a driver load');

select * from finish();
rollback;
