-- eld_link_drivers(): name matching (straight + reversed), fills NULLs only;
-- eld_fleet_live carries the matched driver_id.
begin;
create extension if not exists pgtap with schema extensions;
select plan(6);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000110'::uuid, 'hos@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000110';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000110"}', true);

insert into public.drivers (full_name, status) values ('Marko Petrovic', 'active'), ('Ana Kovac', 'active');

insert into public.eld_drivers (driver_id, first_name, last_name, active)
values ('11111111-1111-4111-8111-111111111101', 'Marko', 'Petrovic', true),   -- straight
       ('11111111-1111-4111-8111-111111111102', 'Kovac', 'Ana', true),        -- reversed roster
       ('11111111-1111-4111-8111-111111111103', 'Totally', 'Unknown', true),   -- no match
       ('11111111-1111-4111-8111-111111111104', 'Jackson Ronald', 'Spencer', true),  -- Last First Middle scramble
       ('11111111-1111-4111-8111-111111111105', 'Bridges Siera', 'Tempra', true);    -- extra middle name

insert into public.drivers (full_name, status) values ('Spencer Ronald Jackson', 'active'), ('Siera Bridges', 'active');

select is(public.eld_link_drivers(), 4, 'four of five ELD drivers link by word-set');
select is(
  (select matched_driver_id from public.eld_drivers where driver_id = '11111111-1111-4111-8111-111111111101'),
  (select id from public.drivers where full_name = 'Marko Petrovic'),
  'straight-order name links');
select is(
  (select matched_driver_id from public.eld_drivers where driver_id = '11111111-1111-4111-8111-111111111102'),
  (select id from public.drivers where full_name = 'Ana Kovac'),
  'reversed-order roster name links');
select is(
  (select matched_driver_id from public.eld_drivers where driver_id = '11111111-1111-4111-8111-111111111104'),
  (select id from public.drivers where full_name = 'Spencer Ronald Jackson'),
  'Last-First-Middle scramble links by word set');
select is(
  (select matched_driver_id from public.eld_drivers where driver_id = '11111111-1111-4111-8111-111111111105'),
  (select id from public.drivers where full_name = 'Siera Bridges'),
  'extra ELD middle name still links (subset match)');

-- fleet feed carries driver_id for the picker
insert into public.trucks (unit_number) values ('HOS-1');
insert into public.eld_vehicles (vehicle_id, number, active, truck_id)
values ('22222222-2222-4222-8222-222222222201', 'HOS-1', true, (select id from public.trucks where unit_number='HOS-1'));
insert into public.eld_vehicle_status (vehicle_id, eld_driver_id, lat, lon, ts)
values ('22222222-2222-4222-8222-222222222201', '11111111-1111-4111-8111-111111111101', 41.8, -87.6, now());
insert into public.eld_driver_status (driver_id, drive_sec) values ('11111111-1111-4111-8111-111111111101', 7200);

select is(
  (select (v->>'driver_id')::bigint from jsonb_array_elements(public.eld_fleet_live()) v
    where v->>'unit' = 'HOS-1'),
  (select id from public.drivers where full_name = 'Marko Petrovic'),
  'eld_fleet_live exposes the matched Truxon driver id');

select * from finish();
rollback;
