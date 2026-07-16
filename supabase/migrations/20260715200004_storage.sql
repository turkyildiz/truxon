-- Truxon TMS — private storage bucket for uploaded documents
-- (BOLs, PODs, licenses, receipts). Object paths follow
-- <entity_type>/<entity_id>/<uuid>_<filename>; metadata lives in
-- public.documents.

insert into storage.buckets (id, name, public, file_size_limit)
values ('documents', 'documents', false, 26214400)  -- 25 MB per file
on conflict (id) do nothing;

create policy documents_bucket_read on storage.objects
  for select to authenticated
  using (bucket_id = 'documents');

create policy documents_bucket_write on storage.objects
  for insert to authenticated
  with check (bucket_id = 'documents');

create policy documents_bucket_delete on storage.objects
  for delete to authenticated
  using (bucket_id = 'documents' and public.my_role() in ('admin', 'dispatcher'));
