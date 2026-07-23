-- Document wallet: driver sees own driver docs + truck road paper, nothing
-- else; storage gate matches the same boundary; office refused.
begin;
create extension if not exists pgtap with schema extensions;
select plan(7);

insert into auth.users (id, email) values
  ('00000000-0000-4000-8000-000000000164'::uuid, 'wa-drv@test.local'),
  ('00000000-0000-4000-8000-000000000165'::uuid, 'wa-drv2@test.local');
update public.profiles set role = 'driver'
 where id in ('00000000-0000-4000-8000-000000000164', '00000000-0000-4000-8000-000000000165');
insert into public.trucks (unit_number, status) values ('WA1', 'available');
insert into public.drivers (full_name, license_number, status, user_id) values
  ('Wallet Driver', 'WA-DL-1', 'active', '00000000-0000-4000-8000-000000000164'),
  ('Other Driver', 'WA-DL-2', 'active', '00000000-0000-4000-8000-000000000165');

insert into public.documents (entity_type, entity_id, doc_type, filename, storage_path, content_type, size_bytes) values
  ('driver', (select id from public.drivers where full_name = 'Wallet Driver'),
   'CDL', 'cdl.pdf', 'drive/hr/cdl-wa1.pdf', 'application/pdf', 100),
  ('driver', (select id from public.drivers where full_name = 'Other Driver'),
   'CDL', 'cdl2.pdf', 'drive/hr/cdl-wa2.pdf', 'application/pdf', 100),
  ('truck', (select id from public.trucks where unit_number = 'WA1'),
   'Registration', 'reg.pdf', 'drive/trucks/reg-wa1.pdf', 'application/pdf', 100),
  ('truck', (select id from public.trucks where unit_number = 'WA1'),
   'POD', 'notwallet.pdf', 'drive/trucks/pod-wa1.pdf', 'application/pdf', 100);

select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000164"}', true);

select is(jsonb_array_length(public.my_wallet_documents()->'driver_docs'), 1,
  'only own driver docs listed');
select is(public.my_wallet_documents()->'driver_docs'->0->>'doc_type', 'CDL', 'CDL present');
select is(jsonb_array_length(public.my_wallet_documents()->'truck_docs'), 1,
  'truck road paper listed, POD excluded');

select ok(public.driver_wallet_path('drive/hr/cdl-wa1.pdf'), 'storage gate: own CDL readable');
select ok(not public.driver_wallet_path('drive/hr/cdl-wa2.pdf'), 'storage gate: other driver CDL blocked');
select ok(not public.driver_wallet_path('drive/trucks/pod-wa1.pdf'), 'storage gate: truck POD blocked');

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000166'::uuid, 'wa-office@test.local');
update public.profiles set role = 'dispatcher' where id = '00000000-0000-4000-8000-000000000166';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000166"}', true);
select throws_ok('select public.my_wallet_documents()', '42501', 'Not enough permissions',
  'office users use the web side');

select * from finish();
rollback;
