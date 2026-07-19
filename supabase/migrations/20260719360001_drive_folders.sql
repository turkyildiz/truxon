-- Drive → real nested folders (Dropbox-like). The storage bytes stay FLAT in
-- the bucket (<uid>/<uuid>_<name>); the whole folder tree is metadata:
--   parent    — the containing folder's full path ('' = root, else 'A/B/C')
--   is_folder — a folder is a row with no storage object
-- So move/rename are pure metadata updates — no shuffling bytes in storage.
-- Existing single-level `folder` labels are migrated to top-level folders.

alter table public.drive_files
  add column if not exists parent text not null default '',
  add column if not exists is_folder boolean not null default false;

-- Folder rows carry no storage object, so storage_path must allow null.
alter table public.drive_files alter column storage_path drop not null;

-- Backfill: an existing file's single-level label becomes its parent path.
update public.drive_files
   set parent = folder
 where parent = '' and folder <> '' and not is_folder;

-- Materialize a folder row for each distinct existing label (per drive), owned
-- by the earliest uploader so team labels don't all collapse to one person.
insert into public.drive_files (drive, owner_id, filename, storage_path, content_type, size_bytes, parent, is_folder)
select df.drive, (array_agg(df.owner_id order by df.uploaded_at))[1], df.folder, null, '', 0, '', true
  from public.drive_files df
 where df.folder <> '' and not df.is_folder
 group by df.drive, df.folder;

create index if not exists drive_files_parent_idx on public.drive_files (drive, parent, is_folder);

-- ---------- RLS: allow reorganizing (UPDATE) ----------
-- Personal already has FOR ALL. The shared Team tree needs UPDATE so anyone can
-- reorganize it; destructive DELETE stays owner-or-admin (unchanged).
drop policy if exists drive_files_team_update on public.drive_files;
create policy drive_files_team_update on public.drive_files
  for update to authenticated
  using (drive = 'team')
  with check (drive = 'team');

-- ---------- folder-aware rename / move / delete ----------
-- SECURITY INVOKER: the row updates/deletes run as the caller, so the existing
-- RLS policies remain the real access control. Folder ops rewrite the parent
-- prefix of every descendant (path math avoids LIKE wildcard pitfalls).

create or replace function public.drive_rename(p_id bigint, p_new_name text)
returns void language plpgsql security invoker set search_path = public as $$
declare r public.drive_files; oldfull text; newfull text; nm text;
begin
  nm := regexp_replace(trim(coalesce(p_new_name, '')), '[/\\]', '_', 'g');
  if nm = '' then raise exception 'Name required'; end if;
  select * into r from public.drive_files where id = p_id;
  if not found then raise exception 'Not found'; end if;
  update public.drive_files set filename = nm where id = p_id;
  if r.is_folder then
    oldfull := case when r.parent = '' then r.filename else r.parent || '/' || r.filename end;
    newfull := case when r.parent = '' then nm else r.parent || '/' || nm end;
    update public.drive_files
       set parent = newfull || substr(parent, length(oldfull) + 1)
     where drive = r.drive
       and (parent = oldfull or left(parent, length(oldfull) + 1) = oldfull || '/');
  end if;
end; $$;

create or replace function public.drive_move(p_ids bigint[], p_new_parent text)
returns void language plpgsql security invoker set search_path = public as $$
declare r public.drive_files; oldfull text; newfull text; np text; i bigint;
begin
  np := coalesce(p_new_parent, '');
  foreach i in array p_ids loop
    select * into r from public.drive_files where id = i;
    if not found then continue; end if;
    if r.is_folder then
      oldfull := case when r.parent = '' then r.filename else r.parent || '/' || r.filename end;
      if np = oldfull or left(np || '/', length(oldfull) + 1) = oldfull || '/' then
        raise exception 'Cannot move a folder into itself';
      end if;
      newfull := case when np = '' then r.filename else np || '/' || r.filename end;
      update public.drive_files set parent = np where id = r.id;
      update public.drive_files
         set parent = newfull || substr(parent, length(oldfull) + 1)
       where drive = r.drive
         and (parent = oldfull or left(parent, length(oldfull) + 1) = oldfull || '/');
    else
      update public.drive_files set parent = np where id = r.id;
    end if;
  end loop;
end; $$;

-- Deletes the selected items (folders take their whole subtree) and RETURNS the
-- storage paths the caller must then remove from the bucket. delete…returning
-- only yields rows RLS actually let the caller delete.
create or replace function public.drive_delete(p_ids bigint[])
returns setof text language plpgsql security invoker set search_path = public as $$
declare r public.drive_files; oldfull text;
begin
  for r in select * from public.drive_files where id = any(p_ids) loop
    if r.is_folder then
      oldfull := case when r.parent = '' then r.filename else r.parent || '/' || r.filename end;
      return query
        delete from public.drive_files
         where drive = r.drive
           and (parent = oldfull or left(parent, length(oldfull) + 1) = oldfull || '/')
        returning storage_path;
      delete from public.drive_files where id = r.id;
    else
      return query delete from public.drive_files where id = r.id returning storage_path;
    end if;
  end loop;
end; $$;

revoke execute on function public.drive_rename(bigint, text) from public, anon;
revoke execute on function public.drive_move(bigint[], text) from public, anon;
revoke execute on function public.drive_delete(bigint[]) from public, anon;
grant execute on function public.drive_rename(bigint, text) to authenticated;
grant execute on function public.drive_move(bigint[], text) to authenticated;
grant execute on function public.drive_delete(bigint[]) to authenticated;
