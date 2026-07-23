-- R9 #145: driver document wallet. Roadside inspections and scale houses ask
-- for the same paper every time — CDL, med card, registration, insurance,
-- permits. The office already files these against the driver/truck entities;
-- the wallet lets the driver PULL their own copies from the cab: a listing RPC
-- plus a storage read policy scoped to exactly those registered documents.
create index if not exists documents_storage_path_idx on public.documents (storage_path);

-- Storage gate: a driver may read an object only if it backs a registered
-- document that belongs in their wallet (their own driver file, or truck
-- road paperwork).
create or replace function public.driver_wallet_path(p_name text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.my_role() = 'driver'
     and exists (
       select 1 from documents d
        where d.storage_path = p_name
          and ((d.entity_type = 'driver' and d.entity_id = public.my_driver_id())
            or (d.entity_type = 'truck' and (
                  d.doc_type ilike '%registration%'
                  or d.doc_type ilike '%insurance%'
                  or d.doc_type ilike '%permit%'
                  or d.doc_type ilike '%ifta%'
                  or d.doc_type ilike '%cab card%')))
     );
$$;
revoke all on function public.driver_wallet_path(text) from public, anon;
grant execute on function public.driver_wallet_path(text) to authenticated;

drop policy if exists documents_bucket_wallet_read_driver on storage.objects;
create policy documents_bucket_wallet_read_driver on storage.objects
  for select to authenticated
  using (bucket_id = 'documents' and public.driver_wallet_path(name));

create or replace function public.my_wallet_documents()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  d_id bigint := public.my_driver_id();
  v_mine jsonb;
  v_truck jsonb;
begin
  if public.my_role() <> 'driver' or d_id is null then
    raise exception 'Not enough permissions' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', d.id, 'doc_type', d.doc_type, 'filename', d.filename,
           'storage_path', d.storage_path, 'uploaded', d.uploaded_at::date)
           order by d.uploaded_at desc), '[]'::jsonb)
    into v_mine
    from documents d
   where d.entity_type = 'driver' and d.entity_id = d_id;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', d.id, 'doc_type', d.doc_type, 'filename', d.filename,
           'storage_path', d.storage_path, 'unit', t.unit_number,
           'uploaded', d.uploaded_at::date)
           order by t.unit_number, d.uploaded_at desc), '[]'::jsonb)
    into v_truck
    from documents d
    join trucks t on t.id = d.entity_id and t.status <> 'retired'
   where d.entity_type = 'truck'
     and (d.doc_type ilike '%registration%'
          or d.doc_type ilike '%insurance%'
          or d.doc_type ilike '%permit%'
          or d.doc_type ilike '%ifta%'
          or d.doc_type ilike '%cab card%');

  return jsonb_build_object('driver_docs', v_mine, 'truck_docs', v_truck);
end;
$$;
revoke all on function public.my_wallet_documents() from public, anon;
grant execute on function public.my_wallet_documents() to authenticated;
