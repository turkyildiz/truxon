-- Drive sharing + folder-path creation: create a share token, refuse to share a
-- folder, and build a nested folder chain idempotently.
begin;
create extension if not exists pgtap with schema extensions;
select plan(5);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-0000000000f2'::uuid, 'share@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-0000000000f2';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000000f2"}', true);

insert into public.drive_files (drive, owner_id, filename, storage_path, is_folder, parent, size_bytes)
  values ('personal','00000000-0000-4000-8000-0000000000f2','report.pdf','u/z_report.pdf', false, '', 99) returning id \gset file_
insert into public.drive_files (drive, owner_id, filename, storage_path, is_folder, parent)
  values ('personal','00000000-0000-4000-8000-0000000000f2','Docs', null, true, '') returning id \gset fold_

-- create a share
select public.drive_create_share(:file_id) as tok \gset
select is(length(:'tok'), 64, 'share token is 64 hex chars');
select ok(exists(select 1 from public.drive_shares where drive_file_id = :file_id and token = :'tok' and not revoked), 'share row created for the file');

-- folders can't be shared
select throws_like($$ select public.drive_create_share((select id from public.drive_files where filename='Docs')) $$,
  '%Only files can be shared%', 'sharing a folder is rejected');

-- ensure a 3-level path
select public.drive_ensure_path('personal', 'A/B/C');
select is(
  (select count(*)::int from public.drive_files where drive='personal' and is_folder
     and ((parent='' and filename='A') or (parent='A' and filename='B') or (parent='A/B' and filename='C'))),
  3, 'ensure_path built the A/B/C folder chain');

-- idempotent
select public.drive_ensure_path('personal', 'A/B/C');
select is(
  (select count(*)::int from public.drive_files where drive='personal' and is_folder and filename in ('A','B','C')),
  3, 'ensure_path is idempotent (no duplicate folders)');

select * from finish();
rollback;
