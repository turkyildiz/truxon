-- Personal Drive + Team Drive (owner request 2026-07-16): a Dropbox-like
-- file area for each employee.
--   Personal Drive — private, only the owner can see or touch their files.
--   Team Drive      — shared, every signed-in staff member can see & add;
--                     a file can be removed by its uploader or an admin.
-- Files live in two private storage buckets; metadata (for listing, folders,
-- who uploaded) lives in public.drive_files.

insert into storage.buckets (id, name, public, file_size_limit)
values
  ('personal', 'personal', false, 104857600),  -- 100 MB / file
  ('team', 'team', false, 104857600)
on conflict (id) do nothing;

create table public.drive_files (
  id bigint generated always as identity primary key,
  drive text not null check (drive in ('personal', 'team')),
  owner_id uuid not null references public.profiles (id) on delete cascade,
  filename text not null,
  storage_path text not null unique,
  content_type text not null default '',
  size_bytes bigint not null default 0,
  folder text not null default '',       -- optional single-level folder label
  uploaded_at timestamptz not null default now()
);

create index drive_files_lookup_idx on public.drive_files (drive, owner_id, folder);

alter table public.drive_files enable row level security;

-- Personal: the owner, and only the owner, can do anything with their rows.
create policy drive_files_personal on public.drive_files
  for all to authenticated
  using (drive = 'personal' and owner_id = auth.uid())
  with check (drive = 'personal' and owner_id = auth.uid());

-- Team: everyone reads; you insert as yourself; you (or an admin) delete.
create policy drive_files_team_read on public.drive_files
  for select to authenticated
  using (drive = 'team');

create policy drive_files_team_insert on public.drive_files
  for insert to authenticated
  with check (drive = 'team' and owner_id = auth.uid());

create policy drive_files_team_delete on public.drive_files
  for delete to authenticated
  using (drive = 'team' and (owner_id = auth.uid() or public.my_role() = 'admin'));

-- ---------- storage object policies ----------
-- Object path convention: <owner_uid>/<optional folder>/<uuid>_<filename>.
-- The first path segment is the owner's uid, which is how personal isolation
-- and team delete-ownership are enforced at the storage layer too.

create policy personal_bucket_all on storage.objects
  for all to authenticated
  using (bucket_id = 'personal' and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id = 'personal' and (storage.foldername(name))[1] = auth.uid()::text);

create policy team_bucket_read on storage.objects
  for select to authenticated
  using (bucket_id = 'team');

create policy team_bucket_insert on storage.objects
  for insert to authenticated
  with check (bucket_id = 'team' and (storage.foldername(name))[1] = auth.uid()::text);

create policy team_bucket_delete on storage.objects
  for delete to authenticated
  using (bucket_id = 'team' and ((storage.foldername(name))[1] = auth.uid()::text or public.my_role() = 'admin'));
