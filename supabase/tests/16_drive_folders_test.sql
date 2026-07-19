-- Drive nested folders: rename/move/delete rewrite the whole descendant subtree
-- (parent-prefix math) and delete returns the storage paths to purge.
begin;
create extension if not exists pgtap with schema extensions;
select plan(6);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-0000000000f1'::uuid, 'drive@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-0000000000f1';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000000f1"}', true);

-- tree: A/ , A/B/ , A/f2.pdf , A/B/f1.pdf
insert into public.drive_files (drive, owner_id, filename, storage_path, is_folder, parent)
  values ('personal','00000000-0000-4000-8000-0000000000f1','A', null, true, '') returning id \gset A_
insert into public.drive_files (drive, owner_id, filename, storage_path, is_folder, parent)
  values ('personal','00000000-0000-4000-8000-0000000000f1','B', null, true, 'A') returning id \gset B_
insert into public.drive_files (drive, owner_id, filename, storage_path, is_folder, parent, size_bytes)
  values ('personal','00000000-0000-4000-8000-0000000000f1','f2.pdf','u/y_f2.pdf', false, 'A', 10) returning id \gset f2_
insert into public.drive_files (drive, owner_id, filename, storage_path, is_folder, parent, size_bytes)
  values ('personal','00000000-0000-4000-8000-0000000000f1','f1.pdf','u/x_f1.pdf', false, 'A/B', 20) returning id \gset f1_

-- rename A -> Docs: descendants reparent
select public.drive_rename(:A_id, 'Docs');
select is((select parent from public.drive_files where id = :f1_id), 'Docs/B', 'rename rewrites deep descendant parent');
select is((select parent from public.drive_files where id = :f2_id), 'Docs', 'rename rewrites direct-child parent');

-- move B (now Docs/B) to root: B and its file follow
select public.drive_move(array[:B_id], '');
select is((select parent from public.drive_files where id = :B_id), '', 'folder moved to root');
select is((select parent from public.drive_files where id = :f1_id), 'B', 'file under moved folder follows');

-- delete Docs (now holds only f2): returns f2 path, purges the subtree
select is(
  (select array_agg(p) from public.drive_delete(array[:A_id]) p where p is not null),
  array['u/y_f2.pdf'], 'delete returns the storage path to purge');
select ok(
  not exists(select 1 from public.drive_files where id in (:A_id, :f2_id))
    and exists(select 1 from public.drive_files where id = :B_id),
  'deleted folder + its file gone; moved-out folder survives');

select * from finish();
rollback;
