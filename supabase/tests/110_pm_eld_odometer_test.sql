-- current_odometer(): the freshest of ELD ECU reading vs fuel-card prompt now
-- feeds the PM engine; a truck with only ELD data finally has an odometer.
begin;
create extension if not exists pgtap with schema extensions;
select plan(3);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000111'::uuid, 'odo@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000111';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000111"}', true);

insert into public.trucks (unit_number) values ('ODO-1'), ('ODO-2');

-- ODO-1: stale fuel prompt (wrong, older) + fresh ELD ECU reading → ELD wins
insert into public.fuel_transactions (uuid, truck_id, transaction_time, prompted_odometer, gallons, amount, fuel_type)
values ('odo1-a', (select id from public.trucks where unit_number='ODO-1'), now() - interval '9 days', 179752, 100, 350, 'Diesel');
insert into public.eld_vehicles (vehicle_id, number, active, truck_id)
values ('33333333-3333-4333-8333-333333333301', 'ODO-1', true, (select id from public.trucks where unit_number='ODO-1'));
insert into public.eld_vehicle_status (vehicle_id, odometer, ts)
values ('33333333-3333-4333-8333-333333333301', 114244.6, now() - interval '1 hour');

-- ODO-2: ELD only (the 9-of-11 live case that used to return NULL)
insert into public.eld_vehicles (vehicle_id, number, active, truck_id)
values ('33333333-3333-4333-8333-333333333302', 'ODO-2', true, (select id from public.trucks where unit_number='ODO-2'));
insert into public.eld_vehicle_status (vehicle_id, odometer, ts)
values ('33333333-3333-4333-8333-333333333302', 295416, now());

select is(
  public.current_odometer((select id from public.trucks where unit_number='ODO-1')),
  114245::bigint, 'fresher ELD ECU reading beats the older pump prompt (rounded)');
select is(
  public.current_odometer((select id from public.trucks where unit_number='ODO-2')),
  295416::bigint, 'ELD-only truck now has an odometer (was NULL before)');
select is(
  (select odometer from public.fleet_odometers() where unit_number = 'ODO-2'),
  295416::bigint, 'fleet_odometers picks up the ELD reading too');

select * from finish();
rollback;
