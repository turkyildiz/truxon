-- TABLET DAY — POD scanner + on-device OCR. Scanned docs arrive with their
-- text already read on the tablet (ML Kit); it lands next to the document so
-- search/extraction/doc-rag get clean text without another vision pass.
-- Whole driver_add_document reproduced from 20260717200001 with p_ocr_text
-- (old signature dropped so the new default-carrying one is unambiguous;
-- older app builds that omit the param keep working).
alter table public.documents add column if not exists ocr_text text;

drop function if exists public.driver_add_document(bigint, text, text, text, bigint, text);

create function public.driver_add_document(
  p_load_id bigint,
  p_storage_path text,
  p_filename text,
  p_content_type text default 'image/jpeg',
  p_size_bytes bigint default 0,
  p_doc_type text default 'pod',
  p_ocr_text text default null
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
    content_type, size_bytes, uploaded_by, ocr_text
  ) values (
    'load', p_load_id, dtype, coalesce(nullif(p_filename, ''), 'photo.jpg'),
    p_storage_path, coalesce(p_content_type, 'image/jpeg'),
    greatest(coalesce(p_size_bytes, 0), 0), auth.uid(),
    nullif(left(coalesce(p_ocr_text, ''), 20000), '')
  )
  returning id into new_id;

  -- Give dispatch visibility on the web side (DEFINER bypasses activity RLS).
  insert into public.activity_log (entity_type, entity_id, user_id, action, detail)
  values ('load', p_load_id, auth.uid(), 'pod_uploaded',
          'Driver uploaded ' || dtype || ' (' || coalesce(nullif(p_filename, ''), 'photo') || ')');

  return jsonb_build_object('id', new_id, 'doc_type', dtype, 'storage_path', p_storage_path);
end;
$$;
revoke all on function public.driver_add_document(bigint, text, text, text, bigint, text, text) from public, anon;
grant execute on function public.driver_add_document(bigint, text, text, text, bigint, text, text) to authenticated, service_role;
