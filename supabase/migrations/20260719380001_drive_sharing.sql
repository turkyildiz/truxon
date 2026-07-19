-- Drive: public share links + folder-upload path creation.
--
-- Share links let anyone with the URL download one file (Dropbox-style). The
-- public download door is the `drive-share` edge function using the service
-- role; RLS here only governs who can CREATE/see/revoke shares. A token maps to
-- exactly one file and can be revoked or expired — it is a bounded capability,
-- never a listing or a traversal.

create table public.drive_shares (
  id bigint generated always as identity primary key,
  token text not null unique,
  drive_file_id bigint not null references public.drive_files (id) on delete cascade,
  created_by uuid not null references public.profiles (id),
  created_at timestamptz not null default now(),
  expires_at timestamptz,                    -- null = never expires (revocable)
  revoked boolean not null default false
);
create index drive_shares_file_idx on public.drive_shares (drive_file_id);

alter table public.drive_shares enable row level security;
-- The creator (or an admin) manages a share. The public download path does NOT
-- use RLS — it goes through the service-role edge function.
create policy drive_shares_rw on public.drive_shares
  for all to authenticated
  using (created_by = auth.uid() or public.my_role() = 'admin')
  with check (created_by = auth.uid());

-- Create a share for a file the caller can access; returns the token. Folders
-- can't be shared as a download link. SECURITY DEFINER so it can mint the token
-- after an explicit access check.
create or replace function public.drive_create_share(p_file_id bigint, p_expires_at timestamptz default null)
returns text language plpgsql security definer set search_path = public as $$
declare f public.drive_files; tok text;
begin
  select * into f from public.drive_files where id = p_file_id;
  if not found then raise exception 'Not found'; end if;
  if f.is_folder or f.storage_path is null then
    raise exception 'Only files can be shared as a download link';
  end if;
  -- personal: only the owner; team: any signed-in staff member.
  if f.drive = 'personal' and f.owner_id <> auth.uid() then
    raise exception 'Not enough permissions';
  end if;
  if f.drive = 'team' and public.my_role() is null then
    raise exception 'Not enough permissions';
  end if;
  tok := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
  insert into public.drive_shares (token, drive_file_id, created_by, expires_at)
    values (tok, p_file_id, auth.uid(), p_expires_at);
  return tok;
end; $$;

-- Ensure a nested folder path exists (used by folder upload), creating any
-- missing segment. Idempotent. INVOKER so RLS governs who can create folders.
create or replace function public.drive_ensure_path(p_drive text, p_path text)
returns void language plpgsql security invoker set search_path = public as $$
declare seg text; cur text := '';
begin
  if coalesce(p_path, '') = '' then return; end if;
  foreach seg in array string_to_array(p_path, '/') loop
    if seg = '' then continue; end if;
    if not exists (
      select 1 from public.drive_files
       where drive = p_drive and parent = cur and filename = seg and is_folder
    ) then
      insert into public.drive_files (drive, owner_id, filename, storage_path, is_folder, parent)
        values (p_drive, auth.uid(), seg, null, true, cur);
    end if;
    cur := case when cur = '' then seg else cur || '/' || seg end;
  end loop;
end; $$;

revoke execute on function public.drive_create_share(bigint, timestamptz) from public, anon;
revoke execute on function public.drive_ensure_path(text, text) from public, anon;
grant execute on function public.drive_create_share(bigint, timestamptz) to authenticated;
grant execute on function public.drive_ensure_path(text, text) to authenticated;
grant select, insert, update on public.drive_shares to service_role;
