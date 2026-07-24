-- R9 #47/#48/#59: route deviation prices out-of-route miles, and GPS-confirmed
-- deliveries without a POD get surfaced; both need breadcrumb coverage.
begin;
create extension if not exists pgtap with schema extensions;
select plan(7);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000197'::uuid, 'rd-disp@test.local');
update public.profiles set role = 'dispatcher' where id = '00000000-0000-4000-8000-000000000197';
insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000198'::uuid, 'rd-drv@test.local');
update public.profiles set role = 'driver' where id = '00000000-0000-4000-8000-000000000198';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000197"}', true);

insert into public.customers (company_name) values ('RD Broker');
insert into public.trucks (unit_number) values ('RD-T');

-- Load booked at 30 miles; the GPS trail wanders ~55 miles (well over) — a
-- deviation. Breadcrumbs walk a path whose great-circle hops sum high.
insert into public.loads (customer_id, rate, miles, status, truck_id, pickup_time, delivery_time,
                          delivery_lat, delivery_lon, delivery_address)
select id, 1000, 30, 'completed', (select id from public.trucks where unit_number='RD-T'),
       now() - interval '2 days', now() - interval '2 days' + interval '3 hours',
       41.50, -81.70, 'Consignee, Cleveland OH'
  from public.customers where company_name='RD Broker';

-- breadcrumb trail: five hops each ~0.15 deg lat apart (~10 mi) = ~40+ driven
insert into public.eld_location_history (id, truck_id, lat, lng, ts)
select gen_random_uuid(), t.id, 41.0 + g * 0.15, -81.7, now() - interval '2 days' + (g || ' minutes')::interval
  from public.trucks t, generate_series(0, 6) g where t.unit_number='RD-T';
-- plus a breadcrumb parked at the consignee around delivery time (for #59)
insert into public.eld_location_history (id, truck_id, lat, lng, ts)
select gen_random_uuid(), t.id, 41.501, -81.701, now() - interval '2 days' + interval '3 hours'
  from public.trucks t where t.unit_number='RD-T';

-- 1-3. route deviation: the load is measured, flagged, and costed
select ok((select (public.route_deviation_report(30, 12)->>'loads_measured')::int >= 1),
  'load with breadcrumbs is measured');
select is((select (public.route_deviation_report(30, 12)->>'flagged')::int), 1,
  'the wandering load is flagged over the threshold');
select ok((select (public.route_deviation_report(30, 12)->>'total_out_of_route_miles')::numeric > 0),
  'out-of-route miles are positive');

-- 4-5. #59: delivery is GPS-confirmed and has no POD → surfaced
select is((select jsonb_array_length(public.gps_confirmed_missing_pod(21, 0.75)->'confirmed_missing_pod')), 1,
  'GPS-confirmed delivery with no POD is surfaced');
select is((select public.gps_confirmed_missing_pod(21, 0.75)->'confirmed_missing_pod'->0->>'customer'), 'RD Broker',
  'the right load is named for a POD chase');

-- 6. once a POD is filed, it drops off the list
insert into public.documents (entity_type, entity_id, doc_type, filename, storage_path)
select 'load', l.id, 'POD', 'pod.pdf', 'test/rd-pod' from public.loads l
  where l.load_number is not null and l.customer_id = (select id from public.customers where company_name='RD Broker');
select is((select jsonb_array_length(public.gps_confirmed_missing_pod(21, 0.75)->'confirmed_missing_pod')), 0,
  'filing the POD clears the suggestion');

-- 7. driver refused
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000198"}', true);
select throws_ok($$ select public.route_deviation_report() $$,
  'Not enough permissions', 'driver cannot see route deviation');

select * from finish();
rollback;
