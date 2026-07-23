-- Fuel receipt capture: driver files a receipt against a truck; wrong storage
-- prefix and office logins are refused.
begin;
create extension if not exists pgtap with schema extensions;
select plan(5);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000162'::uuid, 'fr-drv@test.local');
update public.profiles set role = 'driver' where id = '00000000-0000-4000-8000-000000000162';
insert into public.trucks (unit_number, status) values ('FR1', 'available');
insert into public.drivers (full_name, license_number, status, user_id)
values ('Fuel Driver', 'FR-DL-1', 'active', '00000000-0000-4000-8000-000000000162');

select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000162"}', true);

select ok(
  (public.driver_add_fuel_receipt(
     (select id from public.trucks where unit_number = 'FR1'),
     'fuel/' || (select id from public.drivers where full_name = 'Fuel Driver') || '/1_r.jpg',
     'r.jpg', 'image/jpeg', 12345, 'PILOT #123 DIESEL 98.2 GAL $339.77') ->> 'id') is not null,
  'driver files a fuel receipt');
select is(
  (select count(*)::int from public.documents
    where entity_type = 'truck' and doc_type = 'Fuel Receipt'
      and ocr_text like '%98.2 GAL%'),
  1, 'document lands on the truck with OCR text');
select is(
  (select count(*)::int from public.activity_log where action = 'fuel_receipt_uploaded'),
  1, 'activity logged for the office');

select throws_ok(
  $$ select public.driver_add_fuel_receipt(
       (select id from public.trucks where unit_number = 'FR1'),
       'fuel/999999/1_r.jpg', 'r.jpg') $$,
  '22023', 'Storage path does not match driver', 'foreign fuel prefix refused');

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000163'::uuid, 'fr-office@test.local');
update public.profiles set role = 'accountant' where id = '00000000-0000-4000-8000-000000000163';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000163"}', true);
select throws_ok(
  $$ select public.driver_add_fuel_receipt(
       (select id from public.trucks where unit_number = 'FR1'), 'fuel/1/x.jpg', 'x.jpg') $$,
  '42501', 'Not enough permissions', 'office users refused');

select * from finish();
rollback;
