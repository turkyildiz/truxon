-- ELD telematics: vehicles link to trucks by VIN then unit number, history rows
-- inherit the truck link, and eld_fleet_live joins status + driver + HOS.
begin;
create extension if not exists pgtap with schema extensions;
select plan(7);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-0000000000e1'::uuid, 'eld@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-0000000000e1';

-- two trucks: one matched by VIN, one by unit number
insert into public.trucks (unit_number, vin) values ('3', '3AKJGLDR5JSJH6707'), ('7', 'ZZZNOVINMATCH');

-- ELD vehicles: #003 matches truck 3 by VIN; #7 has no VIN → matches by unit
insert into public.eld_vehicles (vehicle_id, number, vin, active) values
  ('11111111-1111-4111-8111-111111111111', '003', '3AKJGLDR5JSJH6707', true),
  ('22222222-2222-4222-8222-222222222222', '7', '', true);

insert into public.eld_drivers (driver_id, first_name, last_name, active)
  values ('33333333-3333-4333-8333-333333333333', 'Siera', 'Tempra', true);

-- a breadcrumb that arrived before linking (truck_id null)
insert into public.eld_location_history (id, vehicle_id, vehicle_number, lat, lng, ts)
  values ('44444444-4444-4444-8444-444444444444', '11111111-1111-4111-8111-111111111111', '003', 41.8, -87.7, now());

select is(public.eld_link_vehicles() >= 0, true, 'link runs');
select is((select truck_id from public.eld_vehicles where number='003'),
          (select id from public.trucks where unit_number='3'), 'vehicle matched to truck by VIN');
select is((select truck_id from public.eld_vehicles where number='7'),
          (select id from public.trucks where unit_number='7'), 'vehicle matched to truck by unit number (003→3 style)');
select is((select truck_id from public.eld_location_history where id='44444444-4444-4444-8444-444444444444'),
          (select id from public.trucks where unit_number='3'), 'pre-existing breadcrumb inherits the truck link');

-- live status + driver HOS → the fleet feed
insert into public.eld_vehicle_status (vehicle_id, eld_driver_id, number, odometer, lat, lon, status, calc_location, ts)
  values ('11111111-1111-4111-8111-111111111111', '33333333-3333-4333-8333-333333333333', '003', 746926, 41.8, -87.7, 'IN_MOTION', 'Cicero, IL', now());
insert into public.eld_driver_status (driver_id, drive_sec, shift_sec, cycle_sec, current_status)
  values ('33333333-3333-4333-8333-333333333333', 15970, 20185, 108392, 'DS_D');

select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000000e1"}', true);
select is(jsonb_array_length(public.eld_fleet_live()), 1, 'fleet feed returns the active vehicle');
select is(public.eld_fleet_live()->0->>'location', 'Cicero, IL', 'feed carries live location');
select is((public.eld_fleet_live()->0->>'hos_drive_sec')::int, 15970, 'feed carries the driver HOS drive clock');

select * from finish();
rollback;
