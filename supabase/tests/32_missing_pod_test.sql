-- Missing-POD detection: delivered loads without POD evidence surface; a load
-- with a POD document does not; the PODs/ archive cross-reference matches by ref.
begin;
create extension if not exists pgtap with schema extensions;
select plan(9);

insert into public.customers (company_name) values ('POD Test Broker');
insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000e32'::uuid, 'pod@test.local');

-- three delivered loads: one with a POD, one without, one without but archived
insert into public.loads (load_number, customer_id, status, delivery_time, reference_number)
  select 'POD-HAS', id, 'delivered', now() - interval '2 days', 'CMAU1111111' from public.customers where company_name = 'POD Test Broker';
insert into public.loads (load_number, customer_id, status, delivery_time, reference_number)
  select 'POD-MISS', id, 'billed', now() - interval '3 days', 'CMAU2222222' from public.customers where company_name = 'POD Test Broker';
insert into public.loads (load_number, customer_id, status, delivery_time, reference_number)
  select 'POD-ARCH', id, 'completed', now() - interval '4 days', 'CMAU3333333' from public.customers where company_name = 'POD Test Broker';

-- POD-HAS has a pod document
insert into public.documents (entity_type, entity_id, doc_type, filename, storage_path, content_type)
  select 'load', id, 'pod', 'pod.jpg', 'load/pod.jpg', 'image/jpeg' from public.loads where load_number = 'POD-HAS';

-- POD-UPPER has a POD uploaded via the web panel (doc_type stored as 'POD')
insert into public.loads (load_number, customer_id, status, delivery_time, reference_number)
  select 'POD-UPPER', id, 'billed', now() - interval '2 days', 'CMAU4444444' from public.customers where company_name = 'POD Test Broker';
insert into public.documents (entity_type, entity_id, doc_type, filename, storage_path, content_type)
  select 'load', id, 'POD', 'pod.jpg', 'load/pu.jpg', 'image/jpeg' from public.loads where load_number = 'POD-UPPER';

-- the PODs archive contains a file for POD-ARCH's container
insert into public.drive_files (drive, owner_id, filename, storage_path, content_type, is_folder, parent)
  values ('team', '00000000-0000-4000-8000-000000000e32', 'CMAU3333333 POD.jpg', 't/x.jpg', 'image/jpeg', false, 'PODs');

select set_config('request.jwt.claims', '', true);

-- POD-HAS not flagged; POD-MISS and POD-ARCH flagged
select is((select count(*)::int from public.loads_missing_pod(120) where load_number = 'POD-HAS'), 0, 'load with a POD is not flagged');
select is((select count(*)::int from public.loads_missing_pod(120) where load_number = 'POD-MISS'), 1, 'billed load without POD is flagged');
select is((select count(*)::int from public.loads_missing_pod(120) where load_number = 'POD-ARCH'), 1, 'completed load without attached POD is flagged');

-- archive cross-reference (separate, indexed lookup)
select is(public.pod_archive_candidate('CMAU3333333'::text), 'CMAU3333333 POD.jpg', 'archive candidate matched by container ref');
select is(public.pod_archive_candidate('CMAU2222222'::text), null, 'no archive candidate when none exists');

-- a POD stored as 'POD' (web panel casing) still counts — detector is case-insensitive
select is((select count(*)::int from public.loads_missing_pod(120) where load_number = 'POD-UPPER'), 0, 'uppercase POD doc_type is recognized (not flagged)');

-- the attachable archive file for POD-ARCH: id + storage path so the app can copy it
select is((select storage_path from public.pod_archive_candidate_file(
            (select id from public.loads where load_number = 'POD-ARCH'))), 't/x.jpg', 'candidate-file returns the archive file to attach');
select is((select count(*)::int from public.pod_archive_candidate_file(
            (select id from public.loads where load_number = 'POD-MISS'))), 0, 'no candidate-file when nothing matches');

-- summary counts the missing loads (POD-MISS + POD-ARCH; POD-HAS/POD-UPPER excluded)
select is((select (public.loads_missing_pod_summary(120)->>'missing')::int), 2, 'summary counts both missing loads');

select * from finish();
rollback;
