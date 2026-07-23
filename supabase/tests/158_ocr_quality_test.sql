-- OCR quality: a big PDF with no extracted text queues for re-scan.
begin;
create extension if not exists pgtap with schema extensions;
select plan(2);

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000000158'::uuid, 'oq@test.local');
update public.profiles set role = 'admin' where id = '00000000-0000-4000-8000-000000000158';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000158"}', true);

insert into public.customers (company_name) values ('OQ Broker');
insert into public.loads (customer_id, rate, miles) values ((select id from public.customers where company_name='OQ Broker'), 1000, 400);
insert into public.documents (entity_type, entity_id, doc_type, filename, storage_path, content_type, size_bytes, indexed_at) values
  ('load', (select max(id) from public.loads), 'POD', 'garbage-scan.pdf', 't/g.pdf', 'application/pdf', 500000, now()),
  ('load', (select max(id) from public.loads), 'POD', 'clean.pdf', 't/c.pdf', 'application/pdf', 500000, now());
insert into public.document_embeddings (document_id, entity_type, entity_id, chunk_index, content, embedding)
select id, 'load', entity_id, 0, repeat('good text ', 100), array_fill(0.1, array[768])::vector
  from public.documents where filename = 'clean.pdf';

select is((public.ocr_quality_report(25)->>'garbage')::int, 1, 'the textless big PDF is flagged');
select is(
  (select x->>'filename' from jsonb_array_elements(public.ocr_quality_report(25)->'rescan_queue') x limit 1),
  'garbage-scan.pdf', 'and it heads the re-scan queue');

select * from finish();
rollback;
