-- R9 #142: fuel receipt capture at the pump. Card imports carry the numbers,
-- but the paper receipt is the IFTA/audit exhibit — and cash / out-of-network
-- buys have no card record at all. The driver snaps it, on-device OCR text
-- rides along, and it files against the TRUCK so fuel paperwork lives with
-- the unit, not a load.

create or replace function public.driver_owns_fuel_path(p_name text)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if p_name !~ '^fuel/[0-9]+/' then
    return false;
  end if;
  return split_part(p_name, '/', 2)::bigint = public.my_driver_id();
exception when others then
  return false;
end;
$$;
revoke all on function public.driver_owns_fuel_path(text) from public, anon;
grant execute on function public.driver_owns_fuel_path(text) to authenticated;

drop policy if exists documents_bucket_fuel_write_driver on storage.objects;
create policy documents_bucket_fuel_write_driver on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'documents'
    and public.my_role() = 'driver'
    and public.driver_owns_fuel_path(name)
  );

drop policy if exists documents_bucket_fuel_read_driver on storage.objects;
create policy documents_bucket_fuel_read_driver on storage.objects
  for select to authenticated
  using (
    bucket_id = 'documents'
    and public.my_role() = 'driver'
    and public.driver_owns_fuel_path(name)
  );

create or replace function public.driver_add_fuel_receipt(
  p_truck_id bigint,
  p_storage_path text,
  p_filename text,
  p_content_type text default 'image/jpeg',
  p_size_bytes bigint default 0,
  p_ocr_text text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  d_id bigint := public.my_driver_id();
  new_id bigint;
  v_unit text;
begin
  if public.my_role() <> 'driver' or d_id is null then
    raise exception 'Not enough permissions' using errcode = '42501';
  end if;
  select unit_number into v_unit from trucks where id = p_truck_id;
  if not found then
    raise exception 'Truck not found' using errcode = 'P0002';
  end if;
  if p_storage_path !~ ('^fuel/' || d_id::text || '/') then
    raise exception 'Storage path does not match driver' using errcode = '22023';
  end if;

  insert into public.documents (
    entity_type, entity_id, doc_type, filename, storage_path,
    content_type, size_bytes, uploaded_by, ocr_text
  ) values (
    'truck', p_truck_id, 'Fuel Receipt', coalesce(nullif(p_filename, ''), 'receipt.jpg'),
    p_storage_path, coalesce(p_content_type, 'image/jpeg'),
    greatest(coalesce(p_size_bytes, 0), 0), auth.uid(),
    nullif(left(coalesce(p_ocr_text, ''), 20000), '')
  )
  returning id into new_id;

  insert into public.activity_log (entity_type, entity_id, user_id, action, detail)
  values ('truck', p_truck_id, auth.uid(), 'fuel_receipt_uploaded',
          'Driver uploaded fuel receipt for unit ' || coalesce(v_unit, p_truck_id::text));

  return jsonb_build_object('id', new_id, 'storage_path', p_storage_path);
end;
$$;
revoke all on function public.driver_add_fuel_receipt(bigint, text, text, text, bigint, text) from public, anon;
grant execute on function public.driver_add_fuel_receipt(bigint, text, text, text, bigint, text) to authenticated;
