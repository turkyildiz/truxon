-- Companion app: let a driver read their own load paperwork and upload a
-- delivery-receipt / POD photo — nothing else. RBAC hardening
-- (20260716150001) locked the `documents` table and storage bucket to office +
-- maintenance roles, which also (silently) broke driver paperwork reads from
-- the Flutter app. This migration scopes drivers to *their own loads only*,
-- via a helper + narrow storage/RPC surface. Path convention stays
-- `load/<load_id>/<uuid>_<filename>` (same as frontend uploadDocument).

-- ---------- helper: does the current driver own this load? ----------
create or replace function public.driver_owns_load(p_load_id bigint)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.loads l
    where l.id = p_load_id
      and public.my_role() = 'driver'
      and l.driver_id is not distinct from public.my_driver_id()
      and public.my_driver_id() is not null
  );
$$;

revoke all on function public.driver_owns_load(bigint) from public;
revoke execute on function public.driver_owns_load(bigint) from anon;
grant execute on function public.driver_owns_load(bigint) to authenticated;

-- Path form: driver owns the load referenced by a `load/<id>/…` object name.
-- Does its own regex + safe cast so it can NEVER throw inside an RLS policy,
-- no matter what object names exist in the bucket.
create or replace function public.driver_owns_load_path(p_name text)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  seg text;
begin
  if p_name !~ '^load/[0-9]+/' then
    return false;
  end if;
  seg := split_part(p_name, '/', 2);
  return public.driver_owns_load(seg::bigint);
exception when others then
  return false;
end;
$$;

revoke all on function public.driver_owns_load_path(text) from public;
revoke execute on function public.driver_owns_load_path(text) from anon;
grant execute on function public.driver_owns_load_path(text) to authenticated;

-- ---------- storage: drivers read/write only their own load objects ----------
-- Object name looks like `load/123/<uuid>_bol.jpg`; segment 2 is the load id.

drop policy if exists documents_bucket_read_driver on storage.objects;
create policy documents_bucket_read_driver on storage.objects
  for select to authenticated
  using (
    bucket_id = 'documents'
    and public.my_role() = 'driver'
    and public.driver_owns_load_path(name)
  );

drop policy if exists documents_bucket_write_driver on storage.objects;
create policy documents_bucket_write_driver on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'documents'
    and public.my_role() = 'driver'
    and public.driver_owns_load_path(name)
  );

-- ---------- register the uploaded object as a documents row ----------
-- Drivers can't INSERT into public.documents (documents_insert is office-only),
-- so this DEFINER RPC does it after validating ownership and the storage path.
-- doc_type is constrained to the delivery-evidence kinds a driver produces.

create or replace function public.driver_add_document(
  p_load_id bigint,
  p_storage_path text,
  p_filename text,
  p_content_type text default 'image/jpeg',
  p_size_bytes bigint default 0,
  p_doc_type text default 'pod'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  d_id bigint := public.my_driver_id();
  owner bigint;
  new_id bigint;
  dtype text := lower(coalesce(p_doc_type, 'pod'));
begin
  if public.my_role() <> 'driver' or d_id is null then
    raise exception 'Not enough permissions' using errcode = '42501';
  end if;
  if dtype not in ('pod', 'bol', 'receipt', 'photo', 'lumper', 'scale') then
    raise exception 'Invalid document type: %', dtype using errcode = '22023';
  end if;

  select driver_id into owner from public.loads where id = p_load_id;
  if not found then
    raise exception 'Load not found' using errcode = 'P0002';
  end if;
  if owner is distinct from d_id then
    raise exception 'Not your load' using errcode = '42501';
  end if;
  -- The storage object must live under this load's prefix.
  if p_storage_path !~ ('^load/' || p_load_id::text || '/') then
    raise exception 'Storage path does not match load' using errcode = '22023';
  end if;

  insert into public.documents (
    entity_type, entity_id, doc_type, filename, storage_path,
    content_type, size_bytes, uploaded_by
  ) values (
    'load', p_load_id, dtype, coalesce(nullif(p_filename, ''), 'photo.jpg'),
    p_storage_path, coalesce(p_content_type, 'image/jpeg'),
    greatest(coalesce(p_size_bytes, 0), 0), auth.uid()
  )
  returning id into new_id;

  -- Give dispatch visibility on the web side (DEFINER bypasses activity RLS).
  insert into public.activity_log (entity_type, entity_id, user_id, action, detail)
  values ('load', p_load_id, auth.uid(), 'pod_uploaded',
          'Driver uploaded ' || dtype || ' (' || coalesce(nullif(p_filename, ''), 'photo') || ')');

  return jsonb_build_object('id', new_id, 'doc_type', dtype, 'storage_path', p_storage_path);
end;
$$;

revoke all on function public.driver_add_document(bigint, text, text, text, bigint, text) from public;
revoke execute on function public.driver_add_document(bigint, text, text, text, bigint, text) from anon;
grant execute on function public.driver_add_document(bigint, text, text, text, bigint, text) to authenticated;
