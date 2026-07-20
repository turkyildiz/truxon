-- Resolving equipment-enrichment conflicts: an admin sees open conflicts,
-- 'accept' overwrites the field with the document's value, 'keep' dismisses it,
-- and both close the conflict. Non-admins get no rows and cannot resolve.
begin;
create extension if not exists pgtap with schema extensions;
select plan(9);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-0000000c0f01'::uuid, 'cfl-admin@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-0000000c0f01';

insert into public.trucks (unit_number, vin, plate_number)
  values ('CFL1', '1AAAA', 'OLDPLATE'), ('CFL2', '1BBBB', 'KEEPME');

-- one conflict per truck: the doc disagrees with the plate on file
insert into public.equipment_enrichment_log (equipment_type, equipment_id, field, old_value, new_value, action)
  select 'truck', id, 'plate_number', 'OLDPLATE', 'NEWPLATE', 'conflict' from public.trucks where unit_number = 'CFL1';
insert into public.equipment_enrichment_log (equipment_type, equipment_id, field, old_value, new_value, action)
  select 'truck', id, 'plate_number', 'KEEPME', 'IGNORED', 'conflict' from public.trucks where unit_number = 'CFL2';

-- act as the admin
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000c0f01"}', true);

select is((select count(*)::int from public.equipment_conflicts()), 2, 'admin sees both open conflicts');
select is((select unit_number from public.equipment_conflicts() where new_value = 'NEWPLATE'), 'CFL1', 'conflict carries a readable unit label');

-- accept the CFL1 conflict → field overwritten with the document value
select lives_ok($$
  select public.resolve_equipment_conflict((select id from public.equipment_enrichment_log where new_value = 'NEWPLATE'), 'accept')
$$, 'accept resolves without error');
select is((select plate_number from public.trucks where unit_number = 'CFL1'), 'NEWPLATE', 'accept overwrote the field with the document value');

-- keep the CFL2 conflict → field unchanged
select public.resolve_equipment_conflict((select id from public.equipment_enrichment_log where new_value = 'IGNORED'), 'keep');
select is((select plate_number from public.trucks where unit_number = 'CFL2'), 'KEEPME', 'keep left the field unchanged');

-- both are now closed
select is((select count(*)::int from public.equipment_conflicts()), 0, 'resolved conflicts drop off the list');
select is((select resolution from public.equipment_enrichment_log where new_value = 'NEWPLATE'), 'accepted', 'resolution recorded as accepted');
select is((select resolution from public.equipment_enrichment_log where new_value = 'IGNORED'), 'kept', 'resolution recorded as kept');

-- a non-admin cannot resolve
insert into auth.users (id, email) values ('00000000-0000-4000-8000-0000000c0f02'::uuid, 'cfl-driver@test.local');
update public.profiles set role = 'driver' where id = '00000000-0000-4000-8000-0000000c0f02';
insert into public.equipment_enrichment_log (equipment_type, equipment_id, field, old_value, new_value, action)
  select 'truck', id, 'vin', '1BBBB', '1CCCC', 'conflict' from public.trucks where unit_number = 'CFL2';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000c0f02"}', true);
select throws_ok($$
  select public.resolve_equipment_conflict((select id from public.equipment_enrichment_log where new_value = '1CCCC'), 'accept')
$$, 'Not enough permissions', 'a non-admin cannot resolve a conflict');

select * from finish();
rollback;
