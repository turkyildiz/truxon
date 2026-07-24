-- READINESS #182: GPS ingest hardening — ingest_vehicle_positions() is the
-- highest-volume driver-writable endpoint (the companion app streams position
-- batches to it) and is granted to `authenticated`. Bad input here poisons the
-- live fleet map or floods the table, so every guard matters: role/active gate,
-- batch-size caps, and per-point validation (coords, clock skew, staleness,
-- min interval). This proves accepted points land and every reject reason fires.
begin;
create extension if not exists pgtap with schema extensions;
select plan(12);

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-4000-8000-0000000e0001'::uuid, 'gps-d1@test.local',  '{"role":"driver"}'::jsonb),
  ('00000000-0000-4000-8000-0000000e0002'::uuid, 'gps-d2@test.local',  '{"role":"driver"}'::jsonb),
  ('00000000-0000-4000-8000-0000000e0003'::uuid, 'gps-idle@test.local','{"role":"driver"}'::jsonb),
  ('00000000-0000-4000-8000-0000000e00bb'::uuid, 'gps-dead@test.local','{"role":"driver"}'::jsonb),
  ('00000000-0000-4000-8000-0000000e00ff'::uuid, 'gps-disp@test.local','{"role":"dispatcher"}'::jsonb);

insert into public.drivers (full_name, status, user_id) values
  ('GPS Driver One',  'active',     '00000000-0000-4000-8000-0000000e0001'),
  ('GPS Driver Two',  'active',     '00000000-0000-4000-8000-0000000e0002'),
  ('GPS Idle',        'active',     '00000000-0000-4000-8000-0000000e0003'),
  ('GPS Terminated',  'terminated', '00000000-0000-4000-8000-0000000e00bb');

insert into public.customers (company_name) values ('GPS Broker');
insert into public.loads (customer_id, rate, miles, status, driver_id, load_number, delivery_time)
select c.id, 1500, 400, 'in_transit', d.id, 'GPS-1', now() + interval '1 day'
  from public.customers c, public.drivers d where c.company_name='GPS Broker' and d.full_name='GPS Driver One';
insert into public.loads (customer_id, rate, miles, status, driver_id, load_number, delivery_time)
select c.id, 1500, 400, 'in_transit', d.id, 'GPS-2', now() + interval '1 day'
  from public.customers c, public.drivers d where c.company_name='GPS Broker' and d.full_name='GPS Driver Two';

-- helper: build a one-point batch as jsonb
-- (inline via jsonb_build_array in each call)

-- ═══ role / active gates ═══
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000e00ff"}', true);
select throws_ok(
  $$select public.ingest_vehicle_positions('[{"lat":40,"lng":-80,"recorded_at":"2999-01-01"}]'::jsonb)$$,
  '42501', 'Only linked drivers may ingest positions', '1. a non-driver cannot ingest positions');

select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000e00bb"}', true);
select throws_ok(
  format($$select public.ingest_vehicle_positions(jsonb_build_array(jsonb_build_object('lat',40,'lng',-80,'recorded_at',%L)))$$, (now()-interval '2 min')::text),
  '42501', 'Driver not active', '2. a terminated driver cannot ingest positions');

-- ═══ batch-shape guards (as an active driver) ═══
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000e0001"}', true);
select throws_ok(
  $$select public.ingest_vehicle_positions('[]'::jsonb)$$,
  '22023', 'No points', '3. an empty batch is refused');
select throws_ok(
  format($$select public.ingest_vehicle_positions((select jsonb_agg(jsonb_build_object('lat',40,'lng',-80,'recorded_at',%L)) from generate_series(1,61)))$$, (now()-interval '2 min')::text),
  '22023', 'Max 60 points per batch', '4. an over-size batch (61) is refused');

-- ═══ per-point validation (rejections come back in the payload, not as errors) ═══
select is(
  (public.ingest_vehicle_positions(jsonb_build_array(jsonb_build_object('lat',40,'lng',-80,'recorded_at',(now()+interval '30 min')::text)))->'rejected'->0->>'error'),
  'future_timestamp', '5. a future-timestamped point is rejected');
select is(
  (public.ingest_vehicle_positions(jsonb_build_array(jsonb_build_object('lat',40,'lng',-80,'recorded_at',(now()-interval '30 hours')::text)))->'rejected'->0->>'error'),
  'too_old', '6. a stale point (>24h) is rejected');
select is(
  (public.ingest_vehicle_positions(jsonb_build_array(jsonb_build_object('lat',999,'lng',-80,'recorded_at',(now()-interval '2 min')::text)))->'rejected'->0->>'error'),
  'bad_coords', '7. an out-of-range coordinate is rejected');

-- ═══ a valid point is accepted and lands on the live map ═══
select is(
  (public.ingest_vehicle_positions(jsonb_build_array(jsonb_build_object('lat',41.5,'lng',-81.7,'recorded_at',(now()-interval '3 min')::text)))->>'accepted')::int,
  1, '8. a valid point is accepted');
select is(
  (select count(*)::int from public.vehicle_position_current where driver_id = public.my_driver_id()),
  1, '9. the live-map current position is written');

-- ═══ rate limiting: a second point too close in time is dropped (driver two) ═══
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000e0002"}', true);
select is(
  (public.ingest_vehicle_positions(jsonb_build_array(
     jsonb_build_object('lat',41.5,'lng',-81.7,'recorded_at',(now()-interval '5 min')::text),
     jsonb_build_object('lat',41.6,'lng',-81.8,'recorded_at',(now()-interval '5 min'+interval '10 sec')::text)
   ))->>'accepted')::int,
  1, '10. of two points 10s apart, only the first is accepted (min-interval throttle)');

-- ═══ off-duty with no active load is refused; on-duty opens the gate ═══
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000e0003"}', true);
select throws_ok(
  format($$select public.ingest_vehicle_positions(jsonb_build_array(jsonb_build_object('lat',40,'lng',-80,'recorded_at',%L)))$$, (now()-interval '2 min')::text),
  '42501', 'Not on duty and no active load', '11. an idle, off-duty driver cannot ingest');
select public.driver_set_duty(true);
select is(
  (public.ingest_vehicle_positions(jsonb_build_array(jsonb_build_object('lat',40,'lng',-80,'recorded_at',(now()-interval '2 min')::text)))->>'accepted')::int,
  1, '12. once on duty, an idle driver may ingest (no load attached)');

select * from finish();
rollback;
