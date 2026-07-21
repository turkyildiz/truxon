-- Tablet day: DVIR checklist — clean inspections file quietly, defects become
-- reviewable unplanned maintenance, unsafe verdicts shout.
begin;
create extension if not exists pgtap with schema extensions;
select plan(5);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000f88'::uuid, 'dvir-drv@test.local');
update public.profiles set role = 'driver' where id = '00000000-0000-4000-8000-000000000f88';
insert into public.trucks (unit_number, status) values ('DV1', 'available');
insert into public.drivers (full_name, license_number, status, user_id)
values ('Inspect Driver', 'DV-DL-1', 'active', '00000000-0000-4000-8000-000000000f88');

select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000f88"}', true);

-- clean pre-trip: no MX item
select is(
  (public.submit_dvir(
     (select id from public.trucks where unit_number = 'DV1'),
     'pre_trip', '{"brakes":"ok","lights":"ok","tires":"ok"}'::jsonb,
     512000) ->> 'defect_flagged')::boolean,
  false, 'clean inspection flags nothing');
select is((select count(*)::int from public.maintenance_records where source = 'dvir'), 0,
  'no maintenance item for a clean inspection');

-- defective post-trip: MX item appears, needs review, unplanned
select is(
  (public.submit_dvir(
     (select id from public.trucks where unit_number = 'DV1'),
     'post_trip', '{"brakes":"ok","lights":"defect"}'::jsonb,
     512400, 'driver side marker light out', false) ->> 'defect_flagged')::boolean,
  true, 'defect + unsafe flags');
select is(
  (select needs_review and not is_planned from public.maintenance_records where source = 'dvir'),
  true, 'defect lands as unplanned needs-review maintenance');
select matches(
  (select description from public.maintenance_records where source = 'dvir'),
  'NOT SAFE TO OPERATE', 'unsafe verdict is loud in the description');

select * from finish();
rollback;
