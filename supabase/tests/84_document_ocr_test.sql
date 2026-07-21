-- Tablet day: scanned docs carry their on-device OCR text; old app builds
-- that omit the param still work.
begin;
create extension if not exists pgtap with schema extensions;
select plan(4);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000f87'::uuid, 'ocr-drv@test.local');
update public.profiles set role = 'driver' where id = '00000000-0000-4000-8000-000000000f87';
insert into public.customers (company_name) values ('OCR Broker');
insert into public.drivers (full_name, license_number, status, user_id)
values ('Scan Driver', 'OCR-DL-1', 'active', '00000000-0000-4000-8000-000000000f87');
insert into public.loads (load_number, customer_id, status, driver_id, rate, miles)
select 'OCR-1', c.id, 'in_transit', d.id, 1000, 300
  from public.customers c, public.drivers d
 where c.company_name = 'OCR Broker' and d.full_name = 'Scan Driver';

select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000f87"}', true);

select ok(
  (public.driver_add_document(
     (select id from public.loads where load_number = 'OCR-1'),
     'load/' || (select id from public.loads where load_number = 'OCR-1') || '/scan1.jpg',
     'scan1.jpg', 'image/jpeg', 1000, 'receipt',
     'PILOT #423  DIESEL 118.4 GAL  $412.88  OH') ->> 'id') is not null,
  'scanned receipt uploads with OCR text');
select is(
  (select ocr_text from public.documents where filename = 'scan1.jpg'),
  'PILOT #423  DIESEL 118.4 GAL  $412.88  OH',
  'OCR text lands on the document row');

-- old app builds omit the param entirely
select ok(
  (public.driver_add_document(
     (select id from public.loads where load_number = 'OCR-1'),
     'load/' || (select id from public.loads where load_number = 'OCR-1') || '/photo2.jpg',
     'photo2.jpg', 'image/jpeg', 900, 'pod') ->> 'id') is not null,
  'legacy call without p_ocr_text still works');
select is(
  (select ocr_text from public.documents where filename = 'photo2.jpg'),
  null, 'no OCR means null, not empty string');

select * from finish();
rollback;
